import Dependencies
import Foundation
import Logging
import WuhuAPI

/// Manages runner workers: owns the flock, spawns the current-gen worker,
/// drains previous-gen workers, and handles crash/respawn.
///
/// Conforms to ``Runner`` so it can be used as a drop-in replacement for
/// `LocalRunner` from the runner server's perspective. All `Runner` calls
/// are forwarded to the current-gen worker's connection.
public actor WorkerManager: Runner {
  public nonisolated let id: RunnerID

  private let workersRoot: String
  private let runnerName: String
  private let lockProvider: any LockProvider
  private let workerSpawner: any WorkerSpawner
  private let workerConnector: any WorkerConnector
  private let orphanDeadline: Int
  private let logger: Logger

  @Dependency(\.fileIO) private var fileIO

  /// Flock handle — held for the runner's lifetime.
  private var lockHandle: (any LockHandle)?

  /// Current-gen worker state.
  private var currentWorker: WorkerState?

  /// Previous-gen workers being drained.
  private var drainingWorkers: [String: DrainingWorkerState] = [:]

  /// Upstream callbacks (the runner's MuxCallbackSender → server).
  private var upstreamCallbacks: (any RunnerCallbacks)?

  /// Liveness pipe — runner holds write end, worker reads for EOF.
  private var livenessPipe: Pipe?

  /// Epoch provider (overridable for tests).
  private let epochProvider: @Sendable () -> Int

  /// Task monitoring the current worker's callback listener.
  private var currentWorkerListenerTask: Task<Void, Never>?

  /// Buffered results from dead workers discovered before upstream is available.
  private var pendingDeadWorkerResults: [BashFinished] = []

  /// Adopted workers waiting for upstream before starting callback listeners.
  private var pendingAdoptedWorkers: [(directory: String, connection: any WorkerConnectionHandle)] = []

  // MARK: - Init

  public init(
    runnerName: String,
    workersRoot: String,
    lockProvider: any LockProvider,
    workerSpawner: any WorkerSpawner,
    workerConnector: any WorkerConnector,
    orphanDeadline: Int = 3600,
    epochProvider: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
  ) {
    self.runnerName = runnerName
    id = .remote(name: runnerName)
    self.workersRoot = workersRoot
    self.lockProvider = lockProvider
    self.workerSpawner = workerSpawner
    self.workerConnector = workerConnector
    self.orphanDeadline = orphanDeadline
    self.epochProvider = epochProvider
    logger = Logger(label: "WorkerManager")
  }

  // MARK: - Lifecycle

  /// Start the manager: acquire flock, discover old workers, spawn current-gen.
  public func start() async throws {
    // Ensure workers root exists
    try? fileIO.createDirectory(atPath: workersRoot, withIntermediateDirectories: true)

    // 1. Acquire flock
    let lockPath = (workersRoot as NSString).appendingPathComponent("\(runnerName).runner")
    let handle = try lockProvider.acquireExclusive(path: lockPath)
    lockHandle = handle
    logger.info("Acquired flock on \(lockPath)")

    // 2. Discover previous-gen workers
    let discovered = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: runnerName,
      fileIO: fileIO,
      connector: workerConnector,
    )
    logger.info("Found \(discovered.count) previous-gen workers")

    for item in discovered {
      let dirPath = (workersRoot as NSString).appendingPathComponent(item.directory)

      switch item.result {
      case let .alive(connection):
        if let upstream = upstreamCallbacks {
          // Upstream available — wire up and start listening immediately
          await connection.runner.setCallbacks(upstream)
          let listenerTask = Task {
            await connection.startCallbackListener()
            await self.previousGenWorkerDrained(directory: item.directory)
          }
          let state = DrainingWorkerState(
            connection: connection,
            listenerTask: listenerTask,
            directory: item.directory,
          )
          drainingWorkers[item.directory] = state
        } else {
          // No upstream yet — defer listener start until setCallbacks
          pendingAdoptedWorkers.append((directory: item.directory, connection: connection))
        }
        logger.info("Adopted worker \(item.directory)")

      case let .dead(results):
        logger.info("Cleaned up dead worker \(item.directory) (collected \(results.count) results from disk)")
        if let upstream = upstreamCallbacks {
          for finished in results {
            try? await upstream.bashFinished(tag: finished.tag, result: finished.result)
          }
          // Safe to remove — results delivered
          try? FileManager.default.removeItem(atPath: dirPath)
        } else {
          // Buffer results until upstream connects; keep directory until then
          pendingDeadWorkerResults.append(contentsOf: results)
          if results.isEmpty {
            // No results to buffer — safe to clean up now
            try? FileManager.default.removeItem(atPath: dirPath)
          }
        }
      }
    }

    // 3. Spawn current-gen worker
    try await spawnCurrentGenWorker()
  }

  /// Stop the manager: terminate current worker, release flock.
  public func stop() async {
    currentWorkerListenerTask?.cancel()
    currentWorkerListenerTask = nil

    if let worker = currentWorker {
      await worker.connection?.close()
      worker.processHandle?.terminate()
    }
    currentWorker = nil

    for (_, state) in drainingWorkers {
      state.listenerTask.cancel()
      await state.connection.close()
    }
    drainingWorkers.removeAll()

    for item in pendingAdoptedWorkers {
      await item.connection.close()
    }
    pendingAdoptedWorkers.removeAll()
    pendingDeadWorkerResults.removeAll()

    livenessPipe?.fileHandleForWriting.closeFile()
    livenessPipe = nil

    lockHandle?.release()
    lockHandle = nil
  }

  // MARK: - Runner protocol (forwarded to current-gen worker)

  public func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted {
    let runner = try currentRunner()
    return try await runner.startBash(tag: tag, command: command, cwd: cwd, timeout: timeout)
  }

  public func cancelBash(tag: String) async throws -> BashCancelResult {
    let runner = try currentRunner()
    return try await runner.cancelBash(tag: tag)
  }

  public func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    upstreamCallbacks = callbacks

    // Wire up callbacks for current-gen worker
    if let worker = currentWorker, let connection = worker.connection {
      await connection.runner.setCallbacks(callbacks)
    }

    // Wire up callbacks for already-draining workers
    for (_, state) in drainingWorkers {
      await state.connection.runner.setCallbacks(callbacks)
    }

    // Drain buffered dead-worker results
    let pending = pendingDeadWorkerResults
    pendingDeadWorkerResults.removeAll()
    for finished in pending {
      try? await callbacks.bashFinished(tag: finished.tag, result: finished.result)
    }

    // Start callback listeners for adopted workers that were waiting
    let adopted = pendingAdoptedWorkers
    pendingAdoptedWorkers.removeAll()
    for item in adopted {
      await item.connection.runner.setCallbacks(callbacks)
      let listenerTask = Task {
        await item.connection.startCallbackListener()
        await self.previousGenWorkerDrained(directory: item.directory)
      }
      let state = DrainingWorkerState(
        connection: item.connection,
        listenerTask: listenerTask,
        directory: item.directory,
      )
      drainingWorkers[item.directory] = state
    }
  }

  public func readData(path: String) async throws -> Data {
    try await currentRunner().readData(path: path)
  }

  public func readString(path: String, encoding: String.Encoding) async throws -> String {
    try await currentRunner().readString(path: path, encoding: encoding)
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    try await currentRunner().writeData(path: path, data: data, createIntermediateDirectories: createIntermediateDirectories)
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws {
    try await currentRunner().writeString(path: path, content: content, createIntermediateDirectories: createIntermediateDirectories, encoding: encoding)
  }

  public func exists(path: String) async throws -> FileExistence {
    try await currentRunner().exists(path: path)
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    try await currentRunner().listDirectory(path: path)
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    try await currentRunner().enumerateDirectory(root: root)
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    try await currentRunner().createDirectory(path: path, withIntermediateDirectories: withIntermediateDirectories)
  }

  public func find(params: FindParams) async throws -> FindResult {
    try await currentRunner().find(params: params)
  }

  public func grep(params: GrepParams) async throws -> GrepResult {
    try await currentRunner().grep(params: params)
  }

  public func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    try await currentRunner().materialize(params: params)
  }

  // MARK: - Internal

  private func currentRunner() throws -> any Runner {
    guard let connection = currentWorker?.connection else {
      throw WorkerManagerError.noCurrentWorker
    }
    return connection.runner
  }

  private func spawnCurrentGenWorker() async throws {
    let epoch = epochProvider()
    let workerDir = WorkerDirectory.workerPath(
      workersRoot: workersRoot, runnerName: runnerName, epoch: epoch,
    )
    let socketPath = WorkerDirectory.socketPath(workerDir: workerDir)
    let outputDir = WorkerDirectory.outputPath(workerDir: workerDir)

    // Create worker directory and output subdirectory
    try fileIO.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    // Create liveness pipe
    let pipe = Pipe()
    livenessPipe = pipe

    // Spawn the worker process
    let handle = try await workerSpawner.spawn(
      socketPath: socketPath,
      outputDir: outputDir,
      orphanDeadline: orphanDeadline,
      livenessReadEnd: pipe.fileHandleForReading,
    )

    logger.info("Spawned worker \(WorkerDirectory.directoryName(runnerName: runnerName, epoch: epoch))")

    // Wait for the socket to appear
    try await waitForSocket(path: socketPath, timeout: 10.0)

    // Connect to the worker
    let connection = try await workerConnector.connect(socketPath: socketPath)

    // Set callbacks if we have an upstream
    if let upstream = upstreamCallbacks {
      await connection.runner.setCallbacks(upstream)
    }

    currentWorker = WorkerState(
      epoch: epoch,
      connection: connection,
      processHandle: handle,
      directory: workerDir,
    )

    // Start callback listener — monitors for disconnect
    currentWorkerListenerTask = Task { [weak self] in
      await connection.startCallbackListener()
      // Connection dropped — worker may have crashed
      guard let self, !Task.isCancelled else { return }
      await handleCurrentWorkerDisconnect()
    }
  }

  private func handleCurrentWorkerDisconnect() {
    guard let worker = currentWorker else { return }
    let dirName = WorkerDirectory.directoryName(
      runnerName: runnerName, epoch: worker.epoch,
    )
    logger.warning("Worker \(dirName) connection dropped, spawning replacement")

    // Scavenge results from the dead worker's disk
    let outputDir = WorkerDirectory.outputPath(workerDir: worker.directory)
    let results = parseResultFiles(outputDir: outputDir, fileIO: fileIO)
    if !results.isEmpty, let upstream = upstreamCallbacks {
      Task {
        for finished in results {
          try? await upstream.bashFinished(tag: finished.tag, result: finished.result)
        }
      }
    }

    // Clean up dead worker directory
    try? FileManager.default.removeItem(atPath: worker.directory)
    currentWorker = nil

    // Close the old liveness pipe
    livenessPipe?.fileHandleForWriting.closeFile()
    livenessPipe = nil

    // Spawn replacement
    Task {
      do {
        try await self.spawnCurrentGenWorker()
      } catch {
        logger.error("Failed to respawn worker: \(error)")
      }
    }
  }

  private func previousGenWorkerDrained(directory: String) {
    guard let state = drainingWorkers.removeValue(forKey: directory) else { return }
    state.listenerTask.cancel()
    logger.info("Previous-gen worker \(directory) fully drained, removing")
    let dirPath = (workersRoot as NSString).appendingPathComponent(directory)
    try? FileManager.default.removeItem(atPath: dirPath)
  }

  private func waitForSocket(path: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if fileIO.exists(path: path) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
    throw WorkerManagerError.socketTimeout(path)
  }
}

// MARK: - Internal state types

private struct WorkerState: Sendable {
  let epoch: Int
  let connection: (any WorkerConnectionHandle)?
  let processHandle: (any WorkerProcessHandle)?
  let directory: String
}

private struct DrainingWorkerState: Sendable {
  let connection: any WorkerConnectionHandle
  let listenerTask: Task<Void, Never>
  let directory: String
}

// MARK: - Errors

public enum WorkerManagerError: Error, Sendable, CustomStringConvertible {
  case noCurrentWorker
  case socketTimeout(String)

  public var description: String {
    switch self {
    case .noCurrentWorker:
      "No current-gen worker available"
    case let .socketTimeout(path):
      "Worker socket did not appear at \(path) within timeout"
    }
  }
}
