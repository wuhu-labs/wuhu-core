import Foundation
import PiAI
@testable import WuhuCore

// MARK: - MockStreamFn

/// A mock `StreamFn` implementation for testing the full agent loop without a real LLM.
///
/// Supports:
/// - Simple text responses
/// - Tool call responses
/// - Multi-turn scripted sequences
/// - Error simulation on the Nth call
final class MockStreamFn: @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [MockLLMResponse]
  private var callIndex = 0

  /// Captured contexts from each call, for assertions.
  private var _capturedContexts: [Context] = []
  var capturedContexts: [Context] {
    lock.withLock { _capturedContexts }
  }

  var callCount: Int {
    lock.withLock { callIndex }
  }

  init(responses: [MockLLMResponse]) {
    self.responses = responses
  }

  /// Convenience: single text response repeated forever.
  convenience init(text: String) {
    self.init(responses: [.text(text)])
  }

  /// The `StreamFn` closure to pass to `WuhuService`.
  var streamFn: StreamFn {
    { [weak self] model, context, _ in
      guard let self else {
        throw PiAIError.unsupported("MockStreamFn deallocated")
      }
      let response = nextResponse(context: context)
      return makeStream(response: response, model: model)
    }
  }

  private func nextResponse(context: Context) -> MockLLMResponse {
    lock.lock()
    defer { lock.unlock() }
    _capturedContexts.append(context)
    let idx = callIndex
    callIndex += 1
    if responses.isEmpty {
      return .text("default mock response")
    }
    // If we've exhausted the scripted responses, repeat the last one.
    let effective = min(idx, responses.count - 1)
    return responses[effective]
  }

  private func makeStream(
    response: MockLLMResponse,
    model: Model,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    switch response {
    case let .text(text):
      makeTextStream(text: text, model: model)
    case let .toolCalls(calls):
      makeToolCallStream(calls: calls, model: model)
    case let .textAndToolCalls(text, calls):
      makeTextAndToolCallStream(text: text, calls: calls, model: model)
    case let .error(error):
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: error)
      }
    }
  }

  private func makeTextStream(
    text: String,
    model: Model,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      let message = AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: [.text(text)],
        usage: Usage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        stopReason: .stop,
        timestamp: Date(),
      )
      continuation.yield(.start(partial: AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: [],
        stopReason: .stop,
        timestamp: message.timestamp,
      )))
      continuation.yield(.textDelta(delta: text, partial: message))
      continuation.yield(.done(message: message))
      continuation.finish()
    }
  }

  private func makeToolCallStream(
    calls: [MockToolCall],
    model: Model,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      let content: [ContentBlock] = calls.map { call in
        .toolCall(ToolCall(id: call.id, name: call.name, arguments: call.arguments))
      }
      let message = AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: content,
        usage: Usage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        stopReason: .toolUse,
        timestamp: Date(),
      )
      continuation.yield(.start(partial: AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: [],
        stopReason: .toolUse,
        timestamp: message.timestamp,
      )))
      continuation.yield(.done(message: message))
      continuation.finish()
    }
  }

  private func makeTextAndToolCallStream(
    text: String,
    calls: [MockToolCall],
    model: Model,
  ) -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    AsyncThrowingStream { continuation in
      var content: [ContentBlock] = [.text(text)]
      for call in calls {
        content.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: call.arguments)))
      }
      let message = AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: content,
        usage: Usage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
        stopReason: .toolUse,
        timestamp: Date(),
      )
      continuation.yield(.start(partial: AssistantMessage(
        provider: model.provider,
        model: model.id,
        content: [],
        stopReason: .toolUse,
        timestamp: message.timestamp,
      )))
      continuation.yield(.textDelta(delta: text, partial: message))
      continuation.yield(.done(message: message))
      continuation.finish()
    }
  }
}

// MARK: - Response types

enum MockLLMResponse: Sendable {
  /// Return a simple text response.
  case text(String)
  /// Return one or more tool calls.
  case toolCalls([MockToolCall])
  /// Return text + tool calls in the same message.
  case textAndToolCalls(String, [MockToolCall])
  /// Throw an error on this call.
  case error(MockLLMError)
}

struct MockToolCall: Sendable {
  var id: String
  var name: String
  var arguments: JSONValue

  init(id: String = UUID().uuidString.lowercased(), name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

struct MockLLMError: Error, Sendable, CustomStringConvertible {
  var message: String
  var description: String {
    message
  }
}
