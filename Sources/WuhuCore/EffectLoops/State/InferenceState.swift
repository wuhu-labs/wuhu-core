/// Inference lifecycle state — status, retry tracking, errors.
///
/// New capability: retry logic is now state-driven instead of
/// being baked into the loop as `performInferenceWithRetry`.
struct InferenceState: Sendable, Equatable {
  var status: InferenceStatus
  var retryCount: Int
  var retryAfter: ContinuousClock.Instant?
  var lastError: InferenceError?

  static var empty: InferenceState {
    .init(status: .idle, retryCount: 0, retryAfter: nil, lastError: nil)
  }
}

/// Status of the inference subsystem.
enum InferenceStatus: Sendable, Equatable {
  case idle
  case running
  case waitingRetry
  /// Terminal error — inference will not be retried until a new user
  /// message arrives or the session is explicitly restarted.
  case failed
}
