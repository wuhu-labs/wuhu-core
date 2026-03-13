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

// MARK: - Logging wrapper

/// Wraps a `StreamFn` to log LLM request start/end events to stderr via swift-log.
///
/// Logs at `.info` level:
/// - **Start**: requestID, sessionID, model, startTime
/// - **End**: requestID, sessionID, endTime, usage (input/output/total tokens)
public func loggingStreamFn(wrapping inner: @escaping StreamFn, logger: Logger) -> StreamFn {
  { model, context, options in
    let requestID = UUID().uuidString.lowercased()
    let sessionID = options.sessionId ?? "unknown"
    let startTime = Date()

    logger.info(
      "LLM request start",
      metadata: [
        "requestID": "\(requestID)",
        "sessionID": "\(sessionID)",
        "model": "\(model.id)",
        "startTime": "\(iso8601(startTime))",
      ],
    )

    do {
      let stream = try await inner(model, context, options)

      // Wrap the stream to log when it completes
      return AsyncThrowingStream { continuation in
        let task = Task {
          var finalUsage: Usage?
          do {
            for try await event in stream {
              if case let .done(message) = event {
                finalUsage = message.usage
              }
              continuation.yield(event)
            }

            let endTime = Date()
            var metadata: Logger.Metadata = [
              "requestID": "\(requestID)",
              "sessionID": "\(sessionID)",
              "endTime": "\(iso8601(endTime))",
            ]
            if let usage = finalUsage {
              metadata["inputTokens"] = "\(usage.inputTokens)"
              metadata["outputTokens"] = "\(usage.outputTokens)"
              metadata["totalTokens"] = "\(usage.totalTokens)"
            }
            logger.info("LLM request end", metadata: metadata)

            continuation.finish()
          } catch {
            let endTime = Date()
            logger.info(
              "LLM request end",
              metadata: [
                "requestID": "\(requestID)",
                "sessionID": "\(sessionID)",
                "endTime": "\(iso8601(endTime))",
                "error": "\(error)",
              ],
            )

            if Task.isCancelled {
              continuation.finish()
            } else {
              continuation.finish(throwing: error)
            }
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    } catch {
      let endTime = Date()
      logger.info(
        "LLM request end",
        metadata: [
          "requestID": "\(requestID)",
          "sessionID": "\(sessionID)",
          "endTime": "\(iso8601(endTime))",
          "error": "\(error)",
        ],
      )
      throw error
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

// MARK: - Helpers

private func iso8601(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
