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
  public var complete: @Sendable (InferenceRequest) async throws -> AssistantMessage

  public init(complete: @escaping @Sendable (InferenceRequest) async throws -> AssistantMessage) {
    self.complete = complete
  }
}

public struct SleepToolDriver: Sendable {
  public var start: @Sendable (_ toolCallID: String, _ minutes: Int) async throws -> PersistentToolSession

  public init(start: @escaping @Sendable (_ toolCallID: String, _ minutes: Int) async throws -> PersistentToolSession) {
    self.start = start
  }
}

public struct SessionEnvironment: Sendable {
  public var inferenceService: InferenceService
  public var sleepToolDriver: SleepToolDriver
  public var now: @Sendable () -> Date
  public var uuid: @Sendable () -> UUID

  public init(
    inferenceService: InferenceService,
    sleepToolDriver: SleepToolDriver,
    now: @escaping @Sendable () -> Date,
    uuid: @escaping @Sendable () -> UUID
  ) {
    self.inferenceService = inferenceService
    self.sleepToolDriver = sleepToolDriver
    self.now = now
    self.uuid = uuid
  }

  public static func current() -> Self {
    @Dependency(\.wuhuCoreNGInferenceService) var inferenceService
    @Dependency(\.wuhuCoreNGSleepToolDriver) var sleepToolDriver
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    return Self(
      inferenceService: inferenceService,
      sleepToolDriver: sleepToolDriver,
      now: { now },
      uuid: { uuid() }
    )
  }
}

public extension InferenceService {
  static func live(apiKey: String) -> Self {
    let http = AsyncHTTPClientTransport()

    return Self { request in
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

      var finalMessage: AssistantMessage?
      for try await event in stream {
        switch event {
        case let .start(partial):
          finalMessage = partial
        case let .textDelta(_, partial):
          finalMessage = partial
        case let .done(message):
          finalMessage = message
        }
      }

      guard let finalMessage else {
        throw InferenceError.emptyResponse
      }
      return finalMessage
    }
  }
}

public extension SleepToolDriver {
  static let live = Self { toolCallID, minutes in
    let box = SleepTaskBox()

    let events = AsyncStream<PersistentToolEvent> { continuation in
      let task = Task {
        for minute in 1 ... minutes {
          do {
            try await Task.sleep(for: .seconds(60))
          } catch {
            continuation.finish()
            return
          }
          continuation.yield(.progress("\(minute) minute has passed"))
        }

        continuation.yield(
          .completed(
            ToolCallResult(
              content: [.text("Completed \(minutes) minute sleep.")],
              details: .object([
                "toolCallID": .string(toolCallID),
                "minutes": .number(Double(minutes)),
              ])
            )
          )
        )
        continuation.finish()
      }

      Task { await box.set(task) }
      continuation.onTermination = { _ in
        Task { await box.cancel() }
      }
    }

    return PersistentToolSession(
      events: events,
      interrupt: {
        await box.cancel()
      }
    )
  }
}

public enum InferenceError: Error, Sendable {
  case emptyResponse
}

private actor SleepTaskBox {
  private var task: Task<Void, Never>?

  func set(_ task: Task<Void, Never>) {
    self.task = task
  }

  func cancel() {
    task?.cancel()
  }
}

private enum InferenceServiceKey: DependencyKey {
  static let liveValue: InferenceService = .live(apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
  static let testValue: InferenceService = .init { _ in
    throw ToolError.message("InferenceService.testValue was not overridden.")
  }
}

private enum SleepToolDriverKey: DependencyKey {
  static let liveValue: SleepToolDriver = .live
  static let testValue: SleepToolDriver = .init { _, _ in
    throw ToolError.message("SleepToolDriver.testValue was not overridden.")
  }
}

public extension DependencyValues {
  var wuhuCoreNGInferenceService: InferenceService {
    get { self[InferenceServiceKey.self] }
    set { self[InferenceServiceKey.self] = newValue }
  }

  var wuhuCoreNGSleepToolDriver: SleepToolDriver {
    get { self[SleepToolDriverKey.self] }
    set { self[SleepToolDriverKey.self] = newValue }
  }
}
