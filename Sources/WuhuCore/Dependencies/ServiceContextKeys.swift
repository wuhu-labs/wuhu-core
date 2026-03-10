import ServiceContextModule

private enum SessionIDKey: ServiceContextKey {
  typealias Value = String
}

private enum LLMPurposeKey: ServiceContextKey {
  typealias Value = WuhuLLMRequestLogger.Purpose
}

extension ServiceContext {
  var sessionID: String? {
    get { self[SessionIDKey.self] }
    set { self[SessionIDKey.self] = newValue }
  }

  var llmPurpose: WuhuLLMRequestLogger.Purpose? {
    get { self[LLMPurposeKey.self] }
    set { self[LLMPurposeKey.self] = newValue }
  }
}
