import Foundation
import Logging
import PiAI

/// An `HTTPClient` wrapper that logs raw HTTP requests and responses to disk and stderr.
///
/// For each request, creates a directory at:
///   `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
/// containing `request.txt` (headers + body) and `response.txt` (headers + SSE events).
///
/// Sensitive headers (`authorization`, `x-api-key`) are stripped from the logged output.
///
/// Also emits structured swift-log messages at `.info` level for request start/end,
/// including session ID, request ID, model, timing, and usage.
public final class LoggingHTTPTransport: PiAI.HTTPClient, @unchecked Sendable {
  private let underlying: any PiAI.HTTPClient
  private let baseDir: URL
  private let logger: Logger

  private static let sensitiveHeaders: Set<String> = ["authorization", "x-api-key"]

  public init(underlying: any PiAI.HTTPClient, baseDir: URL, logger: Logger) {
    self.underlying = underlying
    self.baseDir = baseDir
    self.logger = logger
  }

  // MARK: - HTTPClient conformance

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    let requestID = UUID().uuidString.lowercased()
    let sessionID = extractSessionID(from: request)
    let model = extractModel(from: request)
    let startTime = Date()

    logger.info(
      "LLM request start",
      metadata: [
        "requestID": "\(requestID)",
        "sessionID": "\(sessionID ?? "unknown")",
        "model": "\(model ?? "unknown")",
        "startTime": "\(iso8601(startTime))",
      ],
    )

    let dir = directoryURL(for: requestID, at: startTime)
    writeRequest(request, to: dir, requestID: requestID)

    do {
      let (responseData, response) = try await underlying.data(for: request)
      let endTime = Date()

      writeDataResponse(response: response, body: responseData, to: dir)

      logger.info(
        "LLM request end",
        metadata: [
          "requestID": "\(requestID)",
          "sessionID": "\(sessionID ?? "unknown")",
          "endTime": "\(iso8601(endTime))",
          "statusCode": "\(response.statusCode)",
          "bodyBytes": "\(responseData.count)",
        ],
      )

      return (responseData, response)
    } catch {
      let endTime = Date()
      logger.info(
        "LLM request end",
        metadata: [
          "requestID": "\(requestID)",
          "sessionID": "\(sessionID ?? "unknown")",
          "endTime": "\(iso8601(endTime))",
          "error": "\(error)",
        ],
      )
      throw error
    }
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let requestID = UUID().uuidString.lowercased()
    let sessionID = extractSessionID(from: request)
    let model = extractModel(from: request)
    let startTime = Date()

    logger.info(
      "LLM request start",
      metadata: [
        "requestID": "\(requestID)",
        "sessionID": "\(sessionID ?? "unknown")",
        "model": "\(model ?? "unknown")",
        "startTime": "\(iso8601(startTime))",
      ],
    )

    let dir = directoryURL(for: requestID, at: startTime)
    writeRequest(request, to: dir, requestID: requestID)

    let sseResponse = try await underlying.sse(for: request)

    // Wrap the SSE event stream to capture events for logging
    let statusCode = sseResponse.response.statusCode
    let responseHeaders = sseResponse.response.headers
    let events = AsyncThrowingStream<SSEMessage, any Error> { continuation in
      let task = Task { [logger, weak self] in
        var captured: [SSEMessage] = []
        do {
          for try await event in sseResponse.events {
            captured.append(event)
            continuation.yield(event)
          }

          let endTime = Date()

          // Extract usage from the final event if present
          let usage = self?.extractUsageFromEvents(captured)

          var endMetadata: Logger.Metadata = [
            "requestID": "\(requestID)",
            "sessionID": "\(sessionID ?? "unknown")",
            "endTime": "\(iso8601(endTime))",
            "statusCode": "\(statusCode)",
            "eventCount": "\(captured.count)",
          ]
          if let usage {
            endMetadata["inputTokens"] = "\(usage.inputTokens)"
            endMetadata["outputTokens"] = "\(usage.outputTokens)"
            endMetadata["totalTokens"] = "\(usage.totalTokens)"
          }

          logger.info("LLM request end", metadata: endMetadata)

          self?.writeSSEResponse(
            response: HTTPResponse(statusCode: statusCode, headers: responseHeaders),
            events: captured,
            to: dir,
          )

          continuation.finish()
        } catch {
          let endTime = Date()

          logger.info(
            "LLM request end",
            metadata: [
              "requestID": "\(requestID)",
              "sessionID": "\(sessionID ?? "unknown")",
              "endTime": "\(iso8601(endTime))",
              "error": "\(error)",
              "eventCount": "\(captured.count)",
            ],
          )

          self?.writeSSEResponse(
            response: HTTPResponse(statusCode: statusCode, headers: responseHeaders),
            events: captured,
            to: dir,
            error: error,
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

    return SSEResponse(response: sseResponse.response, events: events)
  }

  // MARK: - Directory layout

  /// `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
  private func directoryURL(for requestID: String, at date: Date) -> URL {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
    let year = String(format: "%04d", comps.year ?? 0)
    let month = String(format: "%02d", comps.month ?? 0)
    let day = String(format: "%02d", comps.day ?? 0)
    let hour = String(format: "%02d", comps.hour ?? 0)

    return baseDir
      .appendingPathComponent(year)
      .appendingPathComponent(month)
      .appendingPathComponent(day)
      .appendingPathComponent(hour)
      .appendingPathComponent(requestID)
  }

  // MARK: - Request logging

  private func writeRequest(_ request: HTTPRequest, to dir: URL, requestID _: String) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      var lines: [String] = []
      lines.append("\(request.method) \(request.url.absoluteString)")
      lines.append("")

      // Headers (redacted)
      let sortedHeaders = request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
      for (name, values) in sortedHeaders {
        if Self.sensitiveHeaders.contains(name.lowercased()) {
          lines.append("\(name): [REDACTED]")
        } else {
          for value in values {
            lines.append("\(name): \(value)")
          }
        }
      }

      lines.append("")

      // Body
      if let body = request.body {
        if let json = try? JSONSerialization.jsonObject(with: body),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        {
          lines.append(String(decoding: pretty, as: UTF8.self))
        } else {
          lines.append(String(decoding: body, as: UTF8.self))
        }
      }

      let content = lines.joined(separator: "\n")
      try content.write(to: dir.appendingPathComponent("request.txt"), atomically: true, encoding: .utf8)
    } catch {
      // Best-effort: logging must never crash the server.
    }
  }

  // MARK: - Response logging (non-SSE)

  private func writeDataResponse(response: HTTPResponse, body: Data, to dir: URL) {
    do {
      var lines: [String] = []
      lines.append("HTTP \(response.statusCode)")
      lines.append("")

      let sortedHeaders = response.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
      for (name, values) in sortedHeaders {
        for value in values {
          lines.append("\(name): \(value)")
        }
      }

      lines.append("")

      if let json = try? JSONSerialization.jsonObject(with: body),
         let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      {
        lines.append(String(decoding: pretty, as: UTF8.self))
      } else {
        lines.append(String(decoding: body, as: UTF8.self))
      }

      let content = lines.joined(separator: "\n")
      try content.write(to: dir.appendingPathComponent("response.txt"), atomically: true, encoding: .utf8)
    } catch {
      // Best-effort
    }
  }

  // MARK: - Response logging (SSE)

  private func writeSSEResponse(
    response: HTTPResponse,
    events: [SSEMessage],
    to dir: URL,
    error: (any Error)? = nil,
  ) {
    do {
      var lines: [String] = []
      lines.append("HTTP \(response.statusCode)")
      lines.append("")

      let sortedHeaders = response.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
      for (name, values) in sortedHeaders {
        for value in values {
          lines.append("\(name): \(value)")
        }
      }

      lines.append("")
      lines.append("--- SSE Events (\(events.count)) ---")
      lines.append("")

      for (i, event) in events.enumerated() {
        if let eventType = event.event {
          lines.append("event: \(eventType)")
        }
        lines.append("data: \(event.data)")
        if i < events.count - 1 {
          lines.append("")
        }
      }

      if let error {
        lines.append("")
        lines.append("--- Error ---")
        lines.append("\(error)")
      }

      let content = lines.joined(separator: "\n")
      try content.write(to: dir.appendingPathComponent("response.txt"), atomically: true, encoding: .utf8)
    } catch {
      // Best-effort
    }
  }

  // MARK: - Helpers

  /// Try to extract the session ID from the request body or headers.
  private func extractSessionID(from request: HTTPRequest) -> String? {
    // Check common session-related headers
    if let values = request.headers["session_id"], let first = values.first, !first.isEmpty {
      return first
    }
    if let values = request.headers["conversation_id"], let first = values.first, !first.isEmpty {
      return first
    }

    // Try to extract from JSON body
    guard let body = request.body,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }

    if let sid = json["session_id"] as? String, !sid.isEmpty { return sid }
    if let key = json["prompt_cache_key"] as? String, !key.isEmpty { return key }
    return nil
  }

  /// Try to extract the model name from the request body.
  private func extractModel(from request: HTTPRequest) -> String? {
    guard let body = request.body,
          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let model = json["model"] as? String
    else { return nil }
    return model
  }

  /// Try to parse usage information from captured SSE events.
  private func extractUsageFromEvents(_ events: [SSEMessage]) -> (inputTokens: Int, outputTokens: Int, totalTokens: Int)? {
    // Walk events in reverse looking for usage data
    for event in events.reversed() {
      guard let data = event.data.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }

      // Anthropic: usage at top level in message_stop or message_delta events
      if let usage = json["usage"] as? [String: Any] {
        let input = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? 0
        return (input, output, input + output)
      }

      // OpenAI Responses: usage at top level in response.completed
      if let response = json["response"] as? [String: Any],
         let usage = response["usage"] as? [String: Any]
      {
        let input = (usage["input_tokens"] as? Int) ?? (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? (usage["completion_tokens"] as? Int) ?? 0
        let total = (usage["total_tokens"] as? Int) ?? (input + output)
        return (input, output, total)
      }
    }
    return nil
  }
}

private func iso8601(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
