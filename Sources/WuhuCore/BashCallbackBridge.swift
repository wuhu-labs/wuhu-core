import Foundation

/// Server-side bridge that coordinates between `startBash` calls and `bashFinished` callbacks.
///
/// The bash tool calls `waitForResult(tag:)` which suspends until the runner delivers
/// a `bashFinished` callback for that tag. This bridge also implements `RunnerCallbacks`
/// so it can be used directly as the server's callback receiver.
///
/// Used by both:
/// - `LocalRunner` (embedded, for in-process/test usage without mux)
/// - `MuxRunnerCommandsClient` (session-level, receives callbacks from the mux connection)
public actor BashCallbackBridge: RunnerCallbacks {
  private var pending: [String: CheckedContinuation<BashResult, any Error>] = [:]
  private var outputHandlers: [String: @Sendable (String) -> Void] = [:]
  /// Results that arrived before `waitForResult` was called.
  private var buffered: [String: BashResult] = [:]

  public init() {}

  // MARK: - RunnerCallbacks

  public func bashOutput(tag: String, chunk: String) async throws -> Ack {
    outputHandlers[tag]?(chunk)
    return Ack()
  }

  public func bashFinished(tag: String, result: BashResult) async throws -> Ack {
    if let cont = pending.removeValue(forKey: tag) {
      cont.resume(returning: result)
    } else {
      buffered[tag] = result
    }
    outputHandlers.removeValue(forKey: tag)
    return Ack()
  }

  // MARK: - Server-side coordination

  /// Wait for the result of a bash command. Returns immediately if the result has already arrived;
  /// otherwise suspends until `bashFinished` is called for this tag.
  ///
  /// If the outer Swift task is cancelled, the wait is cancelled and `CancellationError` is thrown.
  /// The caller is responsible for calling `cancelBash(tag:)` on the runner to kill the process.
  public func waitForResult(tag: String) async throws -> BashResult {
    if let result = buffered.removeValue(forKey: tag) {
      return result
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        pending[tag] = cont
      }
    } onCancel: {
      Task { await self.cancelWait(tag: tag) }
    }
  }

  /// Cancel the pending wait for a tag (called when the outer task is cancelled).
  private func cancelWait(tag: String) {
    pending.removeValue(forKey: tag)?.resume(throwing: CancellationError())
  }

  /// Register an output chunk handler for a tag (optional streaming callback).
  public func setOutputHandler(tag: String, handler: @escaping @Sendable (String) -> Void) {
    outputHandlers[tag] = handler
  }
}
