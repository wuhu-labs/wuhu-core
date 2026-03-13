import Dependencies
import Foundation
import WuhuAPI

public actor WorkerManager: Runner {
  public nonisolated let id: RunnerID

  private let workersRoot: String
  private let runnerName: String
  private let lockProvider: any LockProvider
  private let workerSpawner: any WorkerSpawner
  private let workerConnector: any WorkerConnector
  private let orphanDeadline: Int
  private let epochProvider: @Sendable () -> Int

  @Dependency(\.fileIO) private var fileIO

  private var lockHandle: (any LockHandle)?
  private var currentWorker: WorkerState?
  private var drainingWorkers: [String: DrainingWorkerState] = [:]
  private var upstreamCallbacks: (any RunnerCallbacks)?
  private var livenessPipe: Pipe?
  private var currentWorkerListenerTask: Task<Void, Never>?
  private var pendingDeadWorkerResults: [BashFinished] = []
  private var pendingAdoptedWorkers: [(directory: String, connection: any WorkerConnectionHandle)] = []

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
  }

  public func start() async throws {
    try? fileIO.createDirectory(atPath: workersRoot, withIntermediateDirectories: true)

    let lockPath = (workersRoot as NSString).appendingPathComponent("\(runnerName).runner")
    lockHandle = try lockProvider.acquireExclusive(path: lockPath)
    stderrLog("acquired flock on \(lockPath)")

    let discovered = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: runnerName,
      fileIO: fileIO,
      connector: workerConnector,
    )
    stderrLog("found \(discovered.count) previous worker generation(s)")

    for item in discovered {
      let dirPath = (workersRoot as NSString).appendingPathComponent(item.directory)
      switch item.result {
      case let .alive(connection):
        if let upstream = upstreamCallbacks {
          let forwarder = WorkerCallbackForwarder(upstream: upstream)
          await connection.runner.setCallbacks(forwarder)
          let listenerTask = Task {
            await connection.startCallbackListener()
            await self.previousGenWorkerDrained(directory: item.directory)
          }
          drainingWorkers[item.directory] = DrainingWorkerState(
            connection: connection,
            listenerTask: listenerTask,
            directory: item.directory,
          )
        } else {
          pendingAdoptedWorkers.append((item.directory, connection))
        }
        stderrLog("adopted worker \(item.directory)")

      case let .dead(results):
        stderrLog("scavenged dead worker \(item.directory) with \(results.count) persisted result(s)")
        if let upstream = upstreamCallbacks {
          for finished in results {
            try? await upstream.bashFinished(tag: finished.tag, result: finished.result)
          }
          try? FileManager.default.removeItem(atPath: dirPath)
        } else {
          pendingDeadWorkerResults.append(contentsOf: results)
          if results.isEmpty {
            try? FileManager.default.removeItem(atPath: dirPath)
          }
        }
      }
    }

    try await spawnCurrentGenWorker()
  }

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

  public func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted {
    try await currentRunner().startBash(tag: tag, command: command, cwd: cwd, timeout: timeout)
  }

  public func cancelBash(tag: String) async throws -> BashCancelResult {
    try await currentRunner().cancelBash(tag: tag)
  }

  public func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    upstreamCallbacks = callbacks

    if let worker = currentWorker, let connection = worker.connection {
      await connection.runner.setCallbacks(WorkerCallbackForwarder(upstream: callbacks))
    }

    for (key, state) in drainingWorkers {
      await state.connection.runner.setCallbacks(WorkerCallbackForwarder(upstream: callbacks))
      drainingWorkers[key] = state
    }

    let pending = pendingDeadWorkerResults
    pendingDeadWorkerResults.removeAll()
    for finished in pending {
      try? await callbacks.bashFinished(tag: finished.tag, result: finished.result)
    }

    let adopted = pendingAdoptedWorkers
    pendingAdoptedWorkers.removeAll()
    for item in adopted {
      await item.connection.runner.setCallbacks(WorkerCallbackForwarder(upstream: callbacks))
      let listenerTask = Task {
        await item.connection.startCallbackListener()
        await self.previousGenWorkerDrained(directory: item.directory)
      }
      drainingWorkers[item.directory] = DrainingWorkerState(
        connection: item.connection,
        listenerTask: listenerTask,
        directory: item.directory,
      )
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

  private func currentRunner() throws -> any Runner {
    guard let connection = currentWorker?.connection else {
      throw WorkerManagerError.noCurrentWorker
    }
    return connection.runner
  }

  private func spawnCurrentGenWorker() async throws {
    let epoch = epochProvider()
    let workerDir = WorkerDirectory.workerPath(workersRoot: workersRoot, runnerName: runnerName, epoch: epoch)
    let socketPath = WorkerDirectory.socketPath(workerDir: workerDir)
    let outputDir = WorkerDirectory.outputPath(workerDir: workerDir)

    try fileIO.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    let pipe = Pipe()
    livenessPipe = pipe

    let handle = try await workerSpawner.spawn(
      socketPath: socketPath,
      outputDir: outputDir,
      orphanDeadline: orphanDeadline,
      livenessReadEnd: pipe.fileHandleForReading,
    )

    stderrLog("spawned worker \(WorkerDirectory.directoryName(runnerName: runnerName, epoch: epoch))")

    try await waitForSocket(path: socketPath, timeout: 10)
    let connection = try await workerConnector.connect(socketPath: socketPath)

    if let upstream = upstreamCallbacks {
      await connection.runner.setCallbacks(WorkerCallbackForwarder(upstream: upstream))
    }

    currentWorker = WorkerState(epoch: epoch, connection: connection, processHandle: handle, directory: workerDir)

    currentWorkerListenerTask = Task { [weak self] in
      await connection.startCallbackListener()
      guard let self, !Task.isCancelled else { return }
      await handleCurrentWorkerDisconnect()
    }
  }

  private func handleCurrentWorkerDisconnect() {
    guard let worker = currentWorker else { return }
    let dirName = WorkerDirectory.directoryName(runnerName: runnerName, epoch: worker.epoch)
    stderrLog("worker \(dirName) disconnected; respawning replacement")

    let outputDir = WorkerDirectory.outputPath(workerDir: worker.directory)
    let results = parseResultFiles(outputDir: outputDir, fileIO: fileIO)
    if !results.isEmpty, let upstream = upstreamCallbacks {
      Task {
        for finished in results {
          try? await upstream.bashFinished(tag: finished.tag, result: finished.result)
        }
      }
    }

    try? FileManager.default.removeItem(atPath: worker.directory)
    currentWorker = nil
    livenessPipe?.fileHandleForWriting.closeFile()
    livenessPipe = nil

    Task {
      do {
        try await self.spawnCurrentGenWorker()
      } catch {
        self.stderrLog("failed to respawn worker: \(error)")
      }
    }
  }

  private func previousGenWorkerDrained(directory: String) {
    guard let state = drainingWorkers.removeValue(forKey: directory) else { return }
    state.listenerTask.cancel()
    stderrLog("previous worker \(directory) fully drained; removing")
    let dirPath = (workersRoot as NSString).appendingPathComponent(directory)
    try? FileManager.default.removeItem(atPath: dirPath)
  }

  private func waitForSocket(path: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if fileIO.exists(path: path) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    throw WorkerManagerError.socketTimeout(path)
  }

  private nonisolated func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data("[WorkerManager] \(message)\n".utf8))
  }
}

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

public enum WorkerManagerError: Error, Sendable, CustomStringConvertible {
  case noCurrentWorker
  case socketTimeout(String)

  public var description: String {
    switch self {
    case .noCurrentWorker:
      "No current worker available"
    case let .socketTimeout(path):
      "Worker socket did not appear at \(path) within timeout"
    }
  }
}
