import Dependencies
import Foundation
import Logging
import PiAI
import ServiceContextModule
import WuhuAPI

public typealias StreamFn = @Sendable (Model, Context, RequestOptions) async throws
  -> AsyncThrowingStream<AssistantMessageEvent, any Error>

// MARK: - Dependency registration

private enum StreamFnKey: DependencyKey {
  static let liveValue: StreamFn = PiAI.streamSimple
  static let testValue: StreamFn = PiAI.streamSimple
}

public extension DependencyValues {
  var streamFn: StreamFn {
    get { self[StreamFnKey.self] }
    set { self[StreamFnKey.self] = newValue }
  }
}

// MARK: - Observed wrapper (stderr + disk in one stream intercept)

private let streamFnLogger = WuhuDebugLogger.logger("LLMRequest")

/// Wrap a `StreamFn` with stderr debug logging and optional disk persistence.
/// SessionID and purpose are read from `ServiceContext.current` via MetadataProvider.
public func observedStreamFn(
  _ base: @escaping StreamFn,
  diskLogger: WuhuLLMRequestLogger? = nil,
) -> StreamFn {
  { model, context, options in
    let ctx = ServiceContext.current
    let sessionID = ctx?.sessionID ?? "unknown"
    let purpose = ctx?.llmPurpose ?? .agent

    let startedAt = Date()
    streamFnLogger.debug(
      "inference started",
      metadata: [
        "provider": "\(model.provider.rawValue)",
        "model": "\(model.id)",
        "messageCount": "\(context.messages.count)",
        "toolCount": "\(context.tools?.count ?? 0)",
      ],
    )

    let request = diskLogger.map { _ in
      WuhuLLMRequestSnapshot(
        model: .init(from: model),
        context: .init(from: context),
        options: .init(from: options),
      )
    }

    let underlying = try await base(model, context, options)

    return AsyncThrowingStream(AssistantMessageEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
      let task = Task {
        var finalMessage: AssistantMessage?
        do {
          for try await event in underlying {
            if case let .done(message) = event {
              finalMessage = message
            }
            continuation.yield(event)
          }

          let finishedAt = Date()
          let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
          streamFnLogger.debug(
            "inference completed",
            metadata: [
              "durationMs": "\(durationMs)",
              "inputTokens": "\(finalMessage?.usage?.inputTokens ?? 0)",
              "outputTokens": "\(finalMessage?.usage?.outputTokens ?? 0)",
              "stopReason": "\(finalMessage?.stopReason.rawValue ?? "unknown")",
            ],
          )

          if let diskLogger, let request {
            await diskLogger.writeLog(
              .init(
                version: 1,
                sessionID: sessionID,
                purpose: purpose,
                startedAt: startedAt,
                finishedAt: finishedAt,
                request: request,
                response: finalMessage.map { .init(from: $0) },
                error: nil,
              ),
            )
          }
          continuation.finish()
        } catch {
          let finishedAt = Date()
          let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
          streamFnLogger.debug(
            "inference failed",
            metadata: [
              "durationMs": "\(durationMs)",
              "error": "\(error)",
            ],
          )

          if let diskLogger, let request {
            await diskLogger.writeLog(
              .init(
                version: 1,
                sessionID: sessionID,
                purpose: purpose,
                startedAt: startedAt,
                finishedAt: finishedAt,
                request: request,
                response: finalMessage.map { .init(from: $0) },
                error: "\(error)",
              ),
            )
          }
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
