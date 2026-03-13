import ServiceContextModule

// MARK: - ServiceContext keys for LLM tracing

private enum LLMCallIDKey: ServiceContextKey {
  typealias Value = String
}

private enum LLMCallDatePathKey: ServiceContextKey {
  typealias Value = String
}

extension ServiceContext {
  /// Unique ID for the current LLM call. Used to coordinate file naming
  /// between the StreamFn span and the HTTP transport span.
  var llmCallID: String? {
    get { self[LLMCallIDKey.self] }
    set { self[LLMCallIDKey.self] = newValue }
  }

  /// Date-based path prefix (e.g. "2025/01/15") for the current LLM call.
  /// Used alongside ``llmCallID`` for payload file paths.
  var llmCallDatePath: String? {
    get { self[LLMCallDatePathKey.self] }
    set { self[LLMCallDatePathKey.self] = newValue }
  }
}
