import Dependencies
import Foundation
import Logging
import PiAI
import PiAIAsyncHTTPClient
import ServiceContextModule
import WuhuAPI

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

// MARK: - Dependency registration

/// Shared HTTP transport for LLM requests. Keep alive for the lifetime of the process to avoid
/// connection teardown mid-stream when providers are created as temporaries.
private let sharedHTTPClient = AsyncHTTPClientTransport()

/// Stream a response from the model using the provider inferred from `model.provider`.
private func streamSimple(
  model: Model,
  context: Context,
  options: RequestOptions,
) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  switch model.provider {
  case .openai:
    try await OpenAIResponsesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
  case .openaiCodex:
    try await OpenAICodexResponsesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
  case .anthropic:
    try await AnthropicMessagesProvider(http: sharedHTTPClient).stream(model: model, context: context, options: options)
  }
}

private enum StreamFnKey: DependencyKey {
  static let liveValue: StreamFn = streamSimple
  static let testValue: StreamFn = streamSimple
}

public extension DependencyValues {
  var streamFn: StreamFn {
    get { self[StreamFnKey.self] }
    set { self[StreamFnKey.self] = newValue }
  }
}

// MARK: - Instrumented HTTP client

/// A version of `sharedHTTPClient` wrapped with ``InstrumentedHTTPClient``
/// for raw HTTP payload capture. Must be configured with a payload store
/// before use via ``configureInstrumentedHTTPClient(payloadStore:)``.
private nonisolated(unsafe) var _instrumentedHTTPClient: (any PiAI.HTTPClient)?

/// Configure the instrumented HTTP client with a payload store.
/// Call this during server startup, before any LLM calls are made.
public func configureInstrumentedHTTPClient(payloadStore: any LLMPayloadStore) {
  _instrumentedHTTPClient = InstrumentedHTTPClient(base: sharedHTTPClient, payloadStore: payloadStore)
}

/// Stream a response using the instrumented HTTP client (with payload capture).
/// Falls back to the plain client if instrumentation hasn't been configured.
public func streamInstrumented(
  model: Model,
  context: Context,
  options: RequestOptions,
) async throws -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
  let http: any PiAI.HTTPClient = _instrumentedHTTPClient ?? sharedHTTPClient
  switch model.provider {
  case .openai:
    return try await OpenAIResponsesProvider(http: http).stream(model: model, context: context, options: options)
  case .openaiCodex:
    return try await OpenAICodexResponsesProvider(http: http).stream(model: model, context: context, options: options)
  case .anthropic:
    return try await AnthropicMessagesProvider(http: http).stream(model: model, context: context, options: options)
  }
}
