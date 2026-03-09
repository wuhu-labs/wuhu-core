import Foundation

/// Callback for bash results that arrive without a waiting continuation.
///
/// This happens when a server restarts and the worker delivers buffered results
/// for tool calls that were in-flight when the server died. The callback should
/// route the result to the appropriate session.
public typealias OrphanedBashResultHandler = @Sendable (
  _ tag: String,
  _ result: BashResult,
) async -> Void

/// Server-side actor that bridges the gap between the fire-and-forget
/// `startBash` RPC and the tool code that needs to `await` a `BashResult`.
///
/// ## Lifecycle
///
/// 1. Tool code calls `runBash(tag:command:runner:cwd:timeout:)`
/// 2. Coordinator sends `startBash` to the runner (returns immediately)
/// 3. Coordinator suspends on a per-tag continuation
/// 4. Runner eventually calls `bashFinished(tag:result:)` via `RunnerCallbacks`
/// 5. Coordinator resumes the continuation with the result
///
/// ## Edge cases handled
///
/// - **Pre-cancel**: `cancel(tag:)` arrives before `runBash`. The tag enters
///   `.cancelled` state; when `runBash` arrives it returns terminated immediately.
/// - **Result before continuation**: `bashFinished` can arrive before `runBash`
///   registers its continuation. The result is buffered in `.resultReady`.
/// - **Orphaned result**: If `onOrphanedResult` is set and `bashFinished` arrives
///   with no waiting continuation, the result is routed via the callback instead
///   of being buffered. This handles server restart recovery.
/// - **Cancel after result**: `cancel(tag:)` after `bashFinished` is a no-op.
public actor BashTagCoordinator: RunnerCallbacks {
  /// Per-tag state machine.
  private enum TagState {
    /// `runBash` is in flight; continuation waiting for result.
    case running(CheckedContinuation<BashResult, any Error>)
    /// `cancel` arrived before `runBash`. When `runBash` arrives, return terminated.
    case cancelled
    /// `bashFinished` arrived before `runBash` registered its continuation.
    case resultReady(BashResult)
  }

  private var tags: [String: TagState] = [:]

  /// Collected output chunks per tag (optional, for tests/logging).
  private var outputChunks: [String: [String]] = [:]

  /// Handler for bash results that arrive without a waiting continuation.
  private var onOrphanedResult: OrphanedBashResultHandler?

  public init() {}

  /// Set the handler for orphaned bash results.
  ///
  /// Call this during server startup to enable routing of recovered results
  /// to their sessions after a server restart.
  public func setOrphanedResultHandler(_ handler: @escaping OrphanedBashResultHandler) {
    onOrphanedResult = handler
  }

  // MARK: - Tool-facing API

  /// Start a bash process on the given runner and await its result.
  ///
  /// This is the main entry point for tool code. It handles the full lifecycle:
  /// start → await callback → return result.
  public func runBash(
    tag: String,
    command: String,
    runner: any Runner,
    cwd: String,
    timeout: TimeInterval?,
  ) async throws -> BashResult {
    // Check for pre-cancel
    if case .cancelled = tags[tag] {
      tags.removeValue(forKey: tag)
      return BashResult(exitCode: -15, output: "", timedOut: false, terminated: true)
    }

    // Send startBash to the runner (returns immediately)
    _ = try await runner.startBash(tag: tag, command: command, cwd: cwd, timeout: timeout)

    // Check if result already arrived (race: bashFinished before we get here)
    if case let .resultReady(result) = tags[tag] {
      tags.removeValue(forKey: tag)
      return result
    }

    // Suspend until bashFinished callback arrives
    return try await withCheckedThrowingContinuation { continuation in
      tags[tag] = .running(continuation)
    }
  }

  /// Cancel a bash process. Sends `cancelBash` to the runner.
  ///
  /// If the tag hasn't started yet, enters `.cancelled` state so `runBash`
  /// returns terminated immediately when it arrives.
  public func cancel(tag: String, runner: any Runner) async {
    switch tags[tag] {
    case let .running(continuation):
      // Resume with terminated result, then send cancel to runner
      tags.removeValue(forKey: tag)
      continuation.resume(returning: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))
      _ = try? await runner.cancelBash(tag: tag)

    case .cancelled:
      // Already cancelled, no-op
      break

    case .resultReady:
      // Already finished, no-op
      break

    case nil:
      // Not started yet — mark as pre-cancelled
      tags[tag] = .cancelled
    }
  }

  /// Get collected output chunks for a tag (for testing).
  public func getOutputChunks(tag: String) -> [String] {
    outputChunks[tag] ?? []
  }

  // MARK: - RunnerCallbacks

  public func bashOutput(tag: String, chunk: String) async throws {
    outputChunks[tag, default: []].append(chunk)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    switch tags[tag] {
    case let .running(continuation):
      tags.removeValue(forKey: tag)
      continuation.resume(returning: result)

    case .cancelled:
      // Was cancelled, ignore the result
      tags.removeValue(forKey: tag)

    case .resultReady:
      // Duplicate finish — shouldn't happen, ignore
      break

    case nil:
      // Result arrived before runBash registered its continuation.
      // This happens during server restart recovery when the worker delivers
      // buffered results for tool calls that were in-flight.
      if let handler = onOrphanedResult {
        // Route to the session via the handler
        await handler(tag, result)
      } else {
        // No handler — buffer it so runBash can pick it up (legacy behavior)
        tags[tag] = .resultReady(result)
      }
    }
  }
}
