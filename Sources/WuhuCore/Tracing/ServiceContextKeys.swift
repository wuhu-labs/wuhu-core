import ServiceContextModule

// MARK: - ServiceContext keys for LLM tracing

private enum LLMCallIDKey: ServiceContextKey {
  typealias Value = String
}

extension ServiceContext {
  /// Unique ID for the current LLM call, set by ``tracedStreamFn``.
  /// Read by ``LoggingHTTPTransport`` to use as the request directory name
  /// instead of generating its own UUID, so that the `llm.call` span and
  /// the `http.request` span reference the same call.
  var llmCallID: String? {
    get { self[LLMCallIDKey.self] }
    set { self[LLMCallIDKey.self] = newValue }
  }
}
