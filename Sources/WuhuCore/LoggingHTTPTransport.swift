import Foundation
import PiAI

/// An `HTTPClient` wrapper that logs raw HTTP requests and responses to disk.
///
/// For each request, creates a directory at:
///   `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
/// containing `request.txt` (headers + body) and `response.txt` (headers + body or SSE events).
///
/// Sensitive headers (`authorization`, `x-api-key`) are stripped from the logged output.
public final class LoggingHTTPTransport: PiAI.HTTPClient, @unchecked Sendable {
  private let underlying: any PiAI.HTTPClient
  private let baseDir: URL

  private static let sensitiveHeaders: Set<String> = ["authorization", "x-api-key"]

  public init(underlying: any PiAI.HTTPClient, baseDir: URL) {
    self.underlying = underlying
    self.baseDir = baseDir
  }

  // MARK: - HTTPClient conformance

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    let requestID = UUID().uuidString.lowercased()
    let dir = directoryURL(for: requestID, at: Date())
    writeRequest(request, to: dir)

    let (responseData, response) = try await underlying.data(for: request)
    writeDataResponse(response: response, body: responseData, to: dir)
    return (responseData, response)
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let requestID = UUID().uuidString.lowercased()
    let dir = directoryURL(for: requestID, at: Date())
    writeRequest(request, to: dir)

    let sseResponse = try await underlying.sse(for: request)

    // Wrap the SSE event stream to capture events for logging
    let statusCode = sseResponse.response.statusCode
    let responseHeaders = sseResponse.response.headers
    let events = AsyncThrowingStream<SSEMessage, any Error> { continuation in
      let task = Task { [weak self] in
        var captured: [SSEMessage] = []
        do {
          for try await event in sseResponse.events {
            captured.append(event)
            continuation.yield(event)
          }

          self?.writeSSEResponse(
            response: HTTPResponse(statusCode: statusCode, headers: responseHeaders),
            events: captured,
            to: dir,
          )

          continuation.finish()
        } catch {
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

  private func writeRequest(_ request: HTTPRequest, to dir: URL) {
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
}
