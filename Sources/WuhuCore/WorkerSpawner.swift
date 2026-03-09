import Foundation

// MARK: - WorkerSpawner protocol

/// Abstraction for spawning worker processes, enabling testability.
public protocol WorkerSpawner: Sendable {
  /// Spawn a worker process with the given socket path and output directory.
  /// Returns a handle that can be used to monitor/kill the worker.
  func spawn(
    socketPath: String,
    outputDir: String,
    orphanDeadline: Int,
    livenessReadEnd: FileHandle,
  ) async throws -> WorkerProcessHandle
}

/// Handle to a spawned worker process.
public protocol WorkerProcessHandle: Sendable {
  var isRunning: Bool { get }
  func terminate()
}

// MARK: - RealWorkerSpawner

/// Spawns `wuhu worker --socket <path> --output-dir <path>` using `Foundation.Process`.
public struct RealWorkerSpawner: WorkerSpawner {
  public init() {}

  public func spawn(
    socketPath: String,
    outputDir: String,
    orphanDeadline: Int,
    livenessReadEnd: FileHandle,
  ) async throws -> WorkerProcessHandle {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    process.arguments = [
      "worker",
      "--socket", socketPath,
      "--output-dir", outputDir,
      "--orphan-deadline", String(orphanDeadline),
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    // The worker reads stdin for liveness — pass the read end; runner holds write end.
    // When runner dies, write end closes → worker sees EOF.
    process.standardInput = livenessReadEnd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError

    try process.run()
    return RealWorkerProcessHandle(process: process)
  }
}

/// Process handle backed by `Foundation.Process`.
final class RealWorkerProcessHandle: WorkerProcessHandle, @unchecked Sendable {
  private let process: Process

  init(process: Process) {
    self.process = process
  }

  var isRunning: Bool {
    process.isRunning
  }

  func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }
}
