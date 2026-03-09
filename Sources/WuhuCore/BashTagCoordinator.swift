import Foundation

/// Handler for bash results arriving from the worker.
/// Routes results to the appropriate session.
public typealias BashResultHandler = @Sendable (
  _ tag: String,
  _ result: BashResult,
) async -> Void

/// Server-side actor that receives bash callbacks from workers and routes
/// them to the appropriate session.
///
/// Bash tool calls are fire-and-forget: the tool calls `runner.startBash()`
/// and returns `.pending`. When the bash completes, the worker sends
/// `bashFinished` which this coordinator routes to the session via the
/// `onResult` handler.
public actor BashTagCoordinator: RunnerCallbacks {
  private var onResult: BashResultHandler?

  public init() {}

  /// Set the handler for bash results.
  /// Call this during server startup.
  public func setResultHandler(_ handler: @escaping BashResultHandler) {
    onResult = handler
  }

  // MARK: - RunnerCallbacks

  public func bashOutput(tag _: String, chunk _: String) async throws {
    // Output chunks could be streamed to the session in the future.
    // For now, they're collected by the worker and included in the final result.
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    guard let handler = onResult else {
      // No handler configured — this shouldn't happen in production.
      let line = "[BashTagCoordinator] WARNING: bashFinished received but no handler configured (tag=\(tag))\n"
      FileHandle.standardError.write(Data(line.utf8))
      return
    }
    await handler(tag, result)
  }
}
