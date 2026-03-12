import Dependencies
import Foundation
import PiAI
import PiAIAsyncHTTPClient

public struct InferenceRequest: Sendable, Hashable {
  public var model: Model
  public var systemPrompt: String
  public var messages: [Message]
  public var tools: [Tool]

  public init(model: Model, systemPrompt: String, messages: [Message], tools: [Tool]) {
    self.model = model
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }
}

public struct InferenceService: Sendable {
  public var stream: @Sendable (InferenceRequest) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error>

  public init(
    stream: @escaping @Sendable (InferenceRequest) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error>
  ) {
    self.stream = stream
  }

  public init(complete: @escaping @Sendable (InferenceRequest) async throws -> AssistantMessage) {
    self.stream = { request in
      AsyncThrowingStream { continuation in
        Task {
          do {
            let message = try await complete(request)
            continuation.yield(.done(message: message))
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      }
    }
  }
}

public struct SessionEnvironment: Sendable {
  public var inferenceService: InferenceService
  public var now: @Sendable () -> Date
  public var uuid: @Sendable () -> UUID

  public init(
    inferenceService: InferenceService,
    now: @escaping @Sendable () -> Date,
    uuid: @escaping @Sendable () -> UUID
  ) {
    self.inferenceService = inferenceService
    self.now = now
    self.uuid = uuid
  }

  public static func current() -> Self {
    @Dependency(\.wuhuSessionInferenceService) var inferenceService
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    return Self(
      inferenceService: inferenceService,
      now: { now },
      uuid: { uuid() }
    )
  }
}

public extension InferenceService {
  static func live(apiKey: String) -> Self {
    let http = AsyncHTTPClientTransport()

    return Self(stream: { request in
      let context = Context(
        systemPrompt: request.systemPrompt,
        messages: request.messages,
        tools: request.tools
      )

      let stream: AsyncThrowingStream<AssistantMessageEvent, any Error>
      switch request.model.provider {
      case .anthropic:
        stream = try await AnthropicMessagesProvider(http: http).stream(
          model: request.model,
          context: context,
          options: .init(maxTokens: 8_192, apiKey: apiKey)
        )
      case .openai:
        stream = try await OpenAIResponsesProvider(http: http).stream(
          model: request.model,
          context: context,
          options: .init(maxTokens: 8_192, apiKey: apiKey)
        )
      case .openaiCodex:
        stream = try await OpenAICodexResponsesProvider(http: http).stream(
          model: request.model,
          context: context,
          options: .init(maxTokens: 8_192, apiKey: apiKey)
        )
      }

      return stream
    })
  }
}

public enum InferenceError: Error, Sendable {
  case emptyResponse
}

private enum InferenceServiceKey: DependencyKey {
  static let liveValue: InferenceService = .live(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
  static let testValue: InferenceService = .init(complete: { _ in
    throw ToolError.message("InferenceService.testValue was not overridden.")
  })
}

public extension DependencyValues {
  var wuhuSessionInferenceService: InferenceService {
    get { self[InferenceServiceKey.self] }
    set { self[InferenceServiceKey.self] = newValue }
  }
}
