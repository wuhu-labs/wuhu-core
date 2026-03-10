import Foundation
import Logging

private let logger = WuhuDebugLogger.logger("BashTagCoordinator")

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

  public func bashOutput(tag: String, chunk: String) async throws {
    logger.debug(
      "coordinator received bashOutput",
      metadata: [
        "tag": "\(tag)",
        "chunkSize": "\(chunk.count)",
      ],
    )
    // Output chunks could be streamed to the session in the future.
    // For now, they're collected by the worker and included in the final result.
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    logger.debug(
      "coordinator received bashFinished",
      metadata: [
        "tag": "\(tag)",
        "exitCode": "\(result.exitCode)",
        "timedOut": "\(result.timedOut)",
        "terminated": "\(result.terminated)",
        "outputSize": "\(result.output.count)",
      ],
    )

    guard let handler = onResult else {
      // No handler configured — this shouldn't happen in production.
      logger.warning(
        "bashFinished received but no handler configured",
        metadata: [
          "tag": "\(tag)",
        ],
      )
      return
    }

    logger.debug(
      "coordinator routing result to session",
      metadata: [
        "tag": "\(tag)",
      ],
    )

    await handler(tag, result)
  }
}
