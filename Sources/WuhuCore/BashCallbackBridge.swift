import Foundation

/// Server-side coordination between fire-and-forget `startBash` and
/// the eventually-arriving `bashFinished` callback from the runner.
///
/// The bash tool calls `startBash`, then `bridge.waitForResult(tag:)`.
/// The bridge holds a continuation that gets resumed when the runner
/// pushes `bashFinished`.
public actor BashCallbackBridge: RunnerCallbacks {
  private var continuations: [String: CheckedContinuation<BashResult, any Error>] = [:]
  private var completedResults: [String: BashResult] = [:]
  private var outputChunks: [String: [String]] = [:]

  public init() {}

  /// Wait for the bash result for a given tag. Suspends until
  /// `bashFinished` is called for this tag.
  public func waitForResult(tag: String) async throws -> BashResult {
    // If the result already arrived before we started waiting, return it.
    if let result = completedResults.removeValue(forKey: tag) {
      return result
    }

    return try await withCheckedThrowingContinuation { continuation in
      continuations[tag] = continuation
    }
  }

  /// Cancel a pending wait. If there's a continuation waiting for this tag,
  /// resume it with a cancellation error.
  public func cancelWait(tag: String) {
    if let continuation = continuations.removeValue(forKey: tag) {
      continuation.resume(throwing: CancellationError())
    }
    completedResults.removeValue(forKey: tag)
    outputChunks.removeValue(forKey: tag)
  }

  // MARK: - RunnerCallbacks

  public nonisolated func bashOutput(tag: String, chunk: String) async throws {
    await _bashOutput(tag: tag, chunk: chunk)
  }

  public nonisolated func bashFinished(tag: String, result: BashResult) async throws {
    await _bashFinished(tag: tag, result: result)
  }

  // MARK: - Actor-isolated implementations

  private func _bashOutput(tag: String, chunk: String) {
    outputChunks[tag, default: []].append(chunk)
  }

  private func _bashFinished(tag: String, result: BashResult) {
    outputChunks.removeValue(forKey: tag)

    if let continuation = continuations.removeValue(forKey: tag) {
      continuation.resume(returning: result)
    } else {
      // Result arrived before waitForResult was called — buffer it.
      completedResults[tag] = result
    }
  }
}
