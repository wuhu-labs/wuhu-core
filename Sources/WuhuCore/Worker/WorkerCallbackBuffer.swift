import Dependencies
import Foundation
import Logging

private let debugLogger = WuhuDebugLogger.logger("WorkerCallbackBuffer")

/// Disk-backed buffered ``RunnerCallbacks`` for use inside a worker process.
///
/// Always persists bash results to disk before acknowledging. When a runner
/// connection is live, results are forwarded immediately and disk files are
/// cleaned up on successful ack. When disconnected, results accumulate in
/// a pending queue and are drained when a runner reconnects.
public actor WorkerCallbackBuffer: RunnerCallbacks {
  /// Live runner connection (nil when disconnected).
  private var connection: (any RunnerCallbacks)?

  /// Results waiting to be pushed to a runner.
  private var pending: [BashFinished] = []

  /// Root directory for persisted output (e.g. `~/.wuhu/workers/<name>/output/`).
  private let outputDir: String

  private let logger = Logger(label: "WorkerCallbackBuffer")

  @Dependency(\.fileIO) private var fileIO

  public init(outputDir: String) {
    self.outputDir = outputDir
  }

  // MARK: - RunnerCallbacks

  public func bashOutput(tag: String, chunk: String) async throws {
    debugLogger.debug(
      "worker buffer received bashOutput",
      metadata: [
        "tag": "\(tag)",
        "chunkSize": "\(chunk.count)",
        "hasConnection": "\(connection != nil)",
      ],
    )
    // Always append to disk
    appendOutputToDisk(tag: tag, chunk: chunk)
    // Forward to live connection (best-effort)
    try? await connection?.bashOutput(tag: tag, chunk: chunk)
  }

  /// Errors thrown when disk persistence fails and there is no live connection
  /// to fall back on.
  public enum PersistenceError: Error {
    case diskWriteFailed(tag: String, underlying: any Error)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    debugLogger.debug(
      "worker buffer received bashFinished",
      metadata: [
        "tag": "\(tag)",
        "exitCode": "\(result.exitCode)",
        "timedOut": "\(result.timedOut)",
        "terminated": "\(result.terminated)",
        "outputSize": "\(result.output.count)",
        "hasConnection": "\(connection != nil)",
      ],
    )

    let finished = BashFinished(tag: tag, result: result)

    // Always persist atomically to disk first
    let persistError = persistResultToDisk(finished)

    if let conn = connection {
      if let persistError {
        // Disk failed but we have a live connection — log warning but still forward
        logger.warning("Disk persist failed for tag \(tag), forwarding to live connection: \(persistError)")
      }
      do {
        debugLogger.debug(
          "worker buffer forwarding bashFinished to runner",
          metadata: [
            "tag": "\(tag)",
          ],
        )
        try await conn.bashFinished(tag: tag, result: result)
        // Ack received — clean up disk files
        debugLogger.debug(
          "worker buffer received ack, cleaning up disk",
          metadata: [
            "tag": "\(tag)",
          ],
        )
        cleanupDiskFiles(tag: tag)
      } catch {
        // Forward failed — queue for later drain
        debugLogger.debug(
          "worker buffer forward failed, queuing",
          metadata: [
            "tag": "\(tag)",
            "error": "\(error)",
          ],
        )
        pending.append(finished)
      }
    } else {
      if let persistError {
        // No connection AND disk failed — durability is lost, propagate error
        throw PersistenceError.diskWriteFailed(tag: tag, underlying: persistError)
      }
      debugLogger.debug(
        "worker buffer queued result (no connection)",
        metadata: [
          "tag": "\(tag)",
          "pendingCount": "\(pending.count + 1)",
        ],
      )
      pending.append(finished)
    }
  }

  // MARK: - Runner connection management

  /// Called when a runner connects (or reconnects). Drains all pending results.
  public func runnerConnected(_ callbacks: any RunnerCallbacks) async {
    debugLogger.debug(
      "worker buffer runner connected, draining pending",
      metadata: [
        "pendingCount": "\(pending.count)",
      ],
    )
    connection = callbacks
    var failed: [BashFinished] = []
    let current = pending
    pending = []
    for item in current {
      do {
        debugLogger.debug(
          "worker buffer draining pending result",
          metadata: [
            "tag": "\(item.tag)",
          ],
        )
        try await callbacks.bashFinished(tag: item.tag, result: item.result)
        cleanupDiskFiles(tag: item.tag)
      } catch {
        debugLogger.debug(
          "worker buffer drain failed, re-queuing",
          metadata: [
            "tag": "\(item.tag)",
            "error": "\(error)",
          ],
        )
        failed.append(item)
      }
    }
    pending = failed
  }

  /// Called when the runner disconnects.
  public func runnerDisconnected() {
    debugLogger.debug("worker buffer runner disconnected")
    connection = nil
  }

  // MARK: - Crash recovery

  /// Scan the output directory for `.result` files not already in the pending
  /// queue. Parses each and adds to pending. Handles crash recovery where the
  /// worker persisted a result but crashed before adding it to the in-memory queue.
  public func recoverFromDisk() {
    let pendingTags = Set(pending.map(\.tag))
    guard let entries = try? fileIO.contentsOfDirectory(atPath: outputDir) else { return }

    for entry in entries {
      guard entry.hasSuffix(".result") else { continue }
      let path = (outputDir as NSString).appendingPathComponent(entry)
      guard let data = try? fileIO.readData(path: path),
            !data.isEmpty
      else { continue }
      guard let finished = try? JSONDecoder().decode(BashFinished.self, from: data) else { continue }
      if !pendingTags.contains(finished.tag) {
        debugLogger.debug(
          "worker buffer recovered result from disk",
          metadata: [
            "tag": "\(finished.tag)",
          ],
        )
        pending.append(finished)
      }
    }
  }

  /// Returns true when the pending queue is empty.
  public func allDrained() -> Bool {
    pending.isEmpty
  }

  /// Returns the current number of pending results (for testing/logging).
  public func pendingCount() -> Int {
    pending.count
  }

  // MARK: - Disk I/O helpers

  private func appendOutputToDisk(tag: String, chunk: String) {
    let path = (outputDir as NSString).appendingPathComponent("\(tag).out")
    let existing = (try? fileIO.readData(path: path)) ?? Data()
    let appended = existing + Data(chunk.utf8)
    do {
      try fileIO.writeData(path: path, data: appended, atomically: false)
    } catch {
      logger.warning("Failed to append output to disk for tag \(tag): \(error)")
    }
  }

  /// Persist a bash result to disk. Returns the error if persistence failed, nil on success.
  @discardableResult
  private func persistResultToDisk(_ finished: BashFinished) -> (any Error)? {
    let path = (outputDir as NSString).appendingPathComponent("\(finished.tag).result")
    do {
      let data = try JSONEncoder().encode(finished)
      try fileIO.writeData(path: path, data: data, atomically: true)
      return nil
    } catch {
      logger.warning("Failed to persist result to disk for tag \(finished.tag): \(error)")
      return error
    }
  }

  private func cleanupDiskFiles(tag: String) {
    // Overwrite with empty data to mark as cleaned. Recovery skips empty files.
    let outPath = (outputDir as NSString).appendingPathComponent("\(tag).out")
    let resultPath = (outputDir as NSString).appendingPathComponent("\(tag).result")
    try? fileIO.writeData(path: outPath, data: Data(), atomically: false)
    try? fileIO.writeData(path: resultPath, data: Data(), atomically: false)
  }
}
