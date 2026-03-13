import Dependencies
import Foundation
import PiAI
import PiAIAsyncHTTPClient
import ServiceContextModule
import Tracing

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

// MARK: - Traced wrapper

/// Wraps a `StreamFn` with a distributed tracing span (`llm.call`).
///
/// Creates a span for each LLM call with structured attributes:
/// - `llm.provider`, `llm.model` — provider and model identifiers
/// - `llm.request.message_count`, `llm.request.tool_count` — request shape
/// - `llm.duration_ms` — wall-clock duration
/// - `llm.usage.input_tokens`, `llm.usage.output_tokens` — token usage
/// - `llm.stop_reason` — how the model stopped
///
/// Sets `ServiceContext.llmCallID` so the HTTP transport layer
/// (``LoggingHTTPTransport``) can reuse the same ID for payload directories
/// and create a correlated child span.
public func tracedStreamFn(wrapping inner: @escaping StreamFn) -> StreamFn {
  { model, context, options in
    let callID = UUID().uuidString.lowercased()

    var ctx = ServiceContext.current ?? .topLevel
    ctx.llmCallID = callID

    // Start span manually — we end it when the stream completes, not when
    // this function returns, because the stream outlives the function scope.
    let span = startSpan("llm.call", context: ctx, ofKind: .client)

    span.attributes["llm.provider"] = model.provider.rawValue
    span.attributes["llm.model"] = model.id
    span.attributes["llm.request.message_count"] = context.messages.count
    span.attributes["llm.request.tool_count"] = context.tools?.count ?? 0
    if let sessionID = options.sessionId {
      span.attributes["llm.session_id"] = sessionID
    }

    let startedAt = Date()

    // Call inner within the span's context so the HTTP transport can read
    // the call ID from ServiceContext.
    let underlying = try await ServiceContext.$current.withValue(span.context) {
      try await inner(model, context, options)
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        var finalMessage: AssistantMessage?
        var caughtError: (any Error)?

        do {
          for try await event in underlying {
            if case let .done(message) = event {
              finalMessage = message
            }
            continuation.yield(event)
          }
        } catch {
          caughtError = error
        }

        // Single finalization path — runs for both success and failure.
        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
        span.attributes["llm.duration_ms"] = durationMs

        if let message = finalMessage {
          span.attributes["llm.stop_reason"] = message.stopReason.rawValue

          if let usage = message.usage {
            span.attributes["llm.usage.input_tokens"] = usage.inputTokens
            span.attributes["llm.usage.output_tokens"] = usage.outputTokens
            span.attributes["llm.usage.total_tokens"] = usage.totalTokens
          }
        }

        if let caughtError {
          span.recordError(caughtError)
          span.setStatus(.init(code: .error, message: "\(caughtError)"))

          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: caughtError)
          }
        } else {
          continuation.finish()
        }

        span.end()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
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
