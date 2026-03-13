import Dependencies
import Foundation
import Logging
import PiAI
import PiAIAsyncHTTPClient

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

// MARK: - Shared transport

/// Shared HTTP transport for LLM requests. Kept alive for the process lifetime to avoid
/// connection teardown mid-stream when providers are created as temporaries.
public let sharedHTTPTransport = AsyncHTTPClientTransport()

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

// MARK: - Dependency registration

private enum StreamFnKey: DependencyKey {
  static let liveValue: StreamFn = makeStreamFn(http: sharedHTTPTransport)
  static let testValue: StreamFn = makeStreamFn(http: sharedHTTPTransport)
}

public extension DependencyValues {
  var streamFn: StreamFn {
    get { self[StreamFnKey.self] }
    set { self[StreamFnKey.self] = newValue }
  }
}
