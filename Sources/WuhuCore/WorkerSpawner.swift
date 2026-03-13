import Foundation

public protocol WorkerSpawner: Sendable {
  func spawn(
    socketPath: String,
    outputDir: String,
    orphanDeadline: Int,
    livenessReadEnd: FileHandle,
  ) async throws -> WorkerProcessHandle
}

public protocol WorkerProcessHandle: Sendable {
  var isRunning: Bool { get }
  func terminate()
}

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
    process.standardInput = livenessReadEnd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    return RealWorkerProcessHandle(process: process)
  }
}

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
