import PiAI

/// Actions for the inference subsystem — status transitions, streaming, retry.
enum InferenceAction: Sendable {
  case started
  case delta(String)
  /// Model stream finished and produced a final assistant message.
  /// Persistence is handled separately.
  case completed(AssistantMessage)
  case failed(InferenceError)
  case retryReady
}

/// Structured error metadata for inference failures, preserving enough
/// information for retry decisions (transient vs permanent).
struct InferenceError: Sendable, Equatable, CustomStringConvertible {
  let message: String
  let httpStatusCode: Int?
  let isTransient: Bool

  var description: String {
    message
  }

  /// Classify an arbitrary error into an ``InferenceError``.
  ///
  /// Mirrors the retry logic from `AgentLoop.isTransientError`:
  /// - PiAI HTTP 429/500/502/503/529 → transient
  /// - Connection/read/connect timeouts → transient
  /// - Everything else → permanent
  static func from(_ error: any Error) -> InferenceError {
    // PiAI HTTP status errors.
    if let piError = error as? PiAIError,
       case let .httpStatus(code, _) = piError
    {
      let transient = code == 429 || code == 500 || code == 502
        || code == 503 || code == 529
      return InferenceError(
        message: String(describing: piError),
        httpStatusCode: code,
        isTransient: transient,
      )
    }

    // AsyncHTTPClient connection-level errors (string-matched because
    // the concrete types are internal to AsyncHTTPClient).
    let desc = String(describing: error)
    if desc.contains("remoteConnectionClosed")
      || desc.contains("connectTimeout")
      || desc.contains("readTimeout")
    {
      return InferenceError(
        message: desc,
        httpStatusCode: nil,
        isTransient: true,
      )
    }

    return InferenceError(
      message: String(describing: error),
      httpStatusCode: nil,
      isTransient: false,
    )
  }
}
