import ServiceContextModule

private enum SessionIDKey: ServiceContextKey {
  typealias Value = String
}

private enum LLMCallIDKey: ServiceContextKey {
  typealias Value = String
}

private enum LLMCallDatePathKey: ServiceContextKey {
  typealias Value = String
}

extension ServiceContext {
  /// The Wuhu session ID. Set by `AgentBehavior.run`, flows down to all child tasks.
  var sessionID: String? {
    get { self[SessionIDKey.self] }
    set { self[SessionIDKey.self] = newValue }
  }

  /// Unique ID for the current LLM call. Used to coordinate file naming
  /// between ``tracedStreamFn`` and ``InstrumentedHTTPClient``.
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
