import Dependencies
import Foundation

/// Disk-backed buffered bash completions for a worker process.
///
/// Final `bashFinished` callbacks are always persisted before being acked. If a
/// runner connection is live they are forwarded immediately and cleaned up after
/// ack; otherwise they accumulate in memory and on disk until reconnect.
///
/// Heartbeats are intentionally live-only and are dropped while disconnected.
public actor WorkerCallbackBuffer: RunnerCallbacks {
  private var connection: (any RunnerCallbacks)?
  private var pending: [BashFinished] = []
  private let outputDir: String

  @Dependency(\.fileIO) private var fileIO

  public init(outputDir: String) {
    self.outputDir = outputDir
  }

  public enum PersistenceError: Error {
    case diskWriteFailed(tag: String, underlying: any Error)
  }

  public func bashHeartbeat(tag: String) async throws {
    try? await connection?.bashHeartbeat(tag: tag)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    let finished = BashFinished(tag: tag, result: result)
    let persistError = persistResultToDisk(finished)

    if let connection {
      if let persistError {
        let line = "[WorkerCallbackBuffer] WARNING: failed to persist result for \(tag), forwarding live anyway: \(persistError)\n"
        FileHandle.standardError.write(Data(line.utf8))
      }
      do {
        try await connection.bashFinished(tag: tag, result: result)
        cleanupDiskFiles(tag: tag)
      } catch {
        pending.append(finished)
      }
    } else {
      if let persistError {
        throw PersistenceError.diskWriteFailed(tag: tag, underlying: persistError)
      }
      pending.append(finished)
    }
  }

  public func runnerConnected(_ callbacks: any RunnerCallbacks) async {
    connection = callbacks
    var failed: [BashFinished] = []
    let current = pending
    pending = []

    for item in current {
      do {
        try await callbacks.bashFinished(tag: item.tag, result: item.result)
        cleanupDiskFiles(tag: item.tag)
      } catch {
        failed.append(item)
      }
    }

    pending = failed
  }

  public func runnerDisconnected() {
    connection = nil
  }

  public func recoverFromDisk() {
    let pendingTags = Set(pending.map(\.tag))
    guard let entries = try? fileIO.contentsOfDirectory(atPath: outputDir) else { return }

    for entry in entries where entry.hasSuffix(".result") {
      let path = (outputDir as NSString).appendingPathComponent(entry)
      guard let data = try? fileIO.readData(path: path), !data.isEmpty else { continue }
      guard let finished = try? JSONDecoder().decode(BashFinished.self, from: data) else { continue }
      if !pendingTags.contains(finished.tag) {
        pending.append(finished)
      }
    }
  }

  public func allDrained() -> Bool {
    pending.isEmpty
  }

  public func pendingCount() -> Int {
    pending.count
  }

  @discardableResult
  private func persistResultToDisk(_ finished: BashFinished) -> (any Error)? {
    let path = (outputDir as NSString).appendingPathComponent("\(finished.tag).result")
    do {
      try fileIO.writeData(path: path, data: JSONEncoder().encode(finished), atomically: true)
      return nil
    } catch {
      let line = "[WorkerCallbackBuffer] WARNING: failed to persist result for \(finished.tag): \(error)\n"
      FileHandle.standardError.write(Data(line.utf8))
      return error
    }
  }

  private func cleanupDiskFiles(tag: String) {
    let resultPath = (outputDir as NSString).appendingPathComponent("\(tag).result")
    try? fileIO.writeData(path: resultPath, data: Data(), atomically: false)
  }
}
