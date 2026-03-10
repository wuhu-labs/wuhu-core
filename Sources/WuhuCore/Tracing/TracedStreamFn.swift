import Foundation
import Logging
import PiAI
import ServiceContextModule
import Tracing
import WuhuAPI

private let logger = Logger(label: "LLMRequest")

/// Wrap a `StreamFn` with OTel tracing.
///
/// Creates a span for each LLM call with structured attributes (provider, model,
/// token usage, cost, stop reason). If no OTel backend is bootstrapped, the span
/// is a no-op — same code path either way.
///
/// Raw HTTP payload capture is handled by ``InstrumentedHTTPClient`` which
/// coordinates with this wrapper via ``LLMCallIDKey`` in `ServiceContext`.
public func tracedStreamFn(_ base: @escaping StreamFn) -> StreamFn {
  { model, context, options in
    // Generate a unique call ID and date prefix for payload file naming.
    // InstrumentedHTTPClient reads these from ServiceContext to write files,
    // and we compute the same paths for span attributes.
    let callID = UUID().uuidString.lowercased()
    let now = Date()
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: now)
    let datePath = String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)

    var ctx = ServiceContext.current ?? .topLevel
    ctx.llmCallID = callID
    ctx.llmCallDatePath = datePath

    // Start span manually — we end it when the stream completes, not when
    // this function returns, because the stream outlives the function scope.
    let span = startSpan("llm.call", context: ctx, ofKind: .client)

    span.attributes["llm.provider"] = model.provider.rawValue
    span.attributes["llm.model"] = model.id
    span.attributes["llm.request.message_count"] = context.messages.count
    span.attributes["llm.request.tool_count"] = context.tools?.count ?? 0
    span.attributes["llm.payload.request_path"] = "\(datePath)/\(callID).request"
    span.attributes["llm.payload.response_path"] = "\(datePath)/\(callID).response"

    let startedAt = Date()

    logger.debug(
      "inference started",
      metadata: [
        "provider": "\(model.provider.rawValue)",
        "model": "\(model.id)",
        "messageCount": "\(context.messages.count)",
        "toolCount": "\(context.tools?.count ?? 0)",
      ],
    )

    // Call the base StreamFn within the span's context so InstrumentedHTTPClient
    // can read the call ID from ServiceContext.
    let underlying = try await ServiceContext.$current.withValue(span.context) {
      try await base(model, context, options)
    }

    return AsyncThrowingStream(AssistantMessageEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
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

        // Single finalization path — runs for both success and failure
        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
        span.attributes["llm.duration_ms"] = durationMs

        if let message = finalMessage {
          span.attributes["llm.stop_reason"] = message.stopReason.rawValue

          if let usage = message.usage {
            span.attributes["llm.usage.input_tokens"] = usage.inputTokens
            span.attributes["llm.usage.output_tokens"] = usage.outputTokens
            // TODO: cache_read_input_tokens / cache_creation_input_tokens
            // once PiAI's Usage type tracks Anthropic cache fields.

            let wuhuProvider = WuhuProvider(from: model.provider)
            let costCents = PricingTable.computeEntryCost(
              provider: wuhuProvider,
              model: model.id,
              usage: WuhuUsage.fromPi(usage),
            )
            span.attributes["llm.cost.hundredths_of_cent"] = Int(costCents)
          }

          logger.debug(
            "inference completed",
            metadata: [
              "durationMs": "\(durationMs)",
              "inputTokens": "\(message.usage?.inputTokens ?? 0)",
              "outputTokens": "\(message.usage?.outputTokens ?? 0)",
              "stopReason": "\(message.stopReason.rawValue)",
            ],
          )
        }

        if let caughtError {
          span.recordError(caughtError)
          span.setStatus(.init(code: .error, message: "\(caughtError)"))

          logger.debug(
            "inference failed",
            metadata: [
              "durationMs": "\(durationMs)",
              "error": "\(caughtError)",
            ],
          )

          continuation.finish(throwing: caughtError)
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
