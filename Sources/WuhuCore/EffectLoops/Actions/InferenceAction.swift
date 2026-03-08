import PiAI

/// Actions for the inference subsystem — status transitions, streaming, retry.
enum InferenceAction: Sendable {
  case started
  case delta(String)
  case completed(AssistantMessage)
  case failed(String)
  case retryReady
}
