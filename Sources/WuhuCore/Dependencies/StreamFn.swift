import Dependencies
import Foundation
import PiAI
import PiAIAsyncHTTPClient

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

// MARK: - Dependency registration

/// Shared HTTP transport for LLM requests. Keep alive for the lifetime of the process to avoid
/// connection teardown mid-stream when providers are created as temporaries.
public let sharedHTTPClient = AsyncHTTPClientTransport()

/// Build a `StreamFn` that dispatches to the appropriate provider using the given HTTP client.
public func makeStreamFn(http: any PiAI.HTTPClient) -> StreamFn {
  { model, context, options in
    switch model.provider {
    case .openai:
      try await OpenAIResponsesProvider(http: http).stream(model: model, context: context, options: options)
    case .openaiCodex:
      try await OpenAICodexResponsesProvider(http: http).stream(model: model, context: context, options: options)
    case .anthropic:
      try await AnthropicMessagesProvider(http: http).stream(model: model, context: context, options: options)
    }
  }
}

private enum StreamFnKey: DependencyKey {
  static let liveValue: StreamFn = makeStreamFn(http: sharedHTTPClient)
  static let testValue: StreamFn = makeStreamFn(http: sharedHTTPClient)
}

public extension DependencyValues {
  var streamFn: StreamFn {
    get { self[StreamFnKey.self] }
    set { self[StreamFnKey.self] = newValue }
  }
}
