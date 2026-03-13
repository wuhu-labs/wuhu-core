import Foundation
import PiAI
import ServiceContextModule
import Tracing

/// An `HTTPClient` wrapper that logs raw HTTP requests and responses to disk,
/// and creates an `http.request` tracing span for each call.
///
/// For each request, creates a directory at:
///   `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
/// containing `request.txt` (headers + body) and `response.txt` (headers + body or SSE events).
///
/// The span records:
/// - `http.method`, `http.url`, `http.status_code` — request/response metadata
/// - `http.request.header.*`, `http.response.header.*` — non-sensitive headers
/// - `http.payload.request_path`, `http.payload.response_path` — relative paths to payload files
///
/// If a `llmCallID` is present in the current `ServiceContext` (set by
/// ``tracedStreamFn``), it is used as the request directory name instead of
/// a fresh UUID, so the `llm.call` span and payload directory share the same ID.
///
/// Sensitive headers (`authorization`, `x-api-key`) are redacted.
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
    let (dir, relativeDir, span) = beginRequest(request)
    writeRequest(request, to: dir)
    span.attributes["http.payload.request_path"] = "\(relativeDir)/request.txt"

    let responseData: Data
    let response: HTTPResponse
    do {
      (responseData, response) = try await underlying.data(for: request)
    } catch {
      span.recordError(error)
      span.setStatus(.init(code: .error, message: "\(error)"))
      span.end()
      throw error
    }

    span.attributes["http.status_code"] = response.statusCode
    setHeaderAttributes(response.headers, prefix: "http.response.header", on: span)

    writeDataResponse(response: response, body: responseData, to: dir)
    span.attributes["http.payload.response_path"] = "\(relativeDir)/response.txt"
    span.end()

    return (responseData, response)
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let (dir, relativeDir, span) = beginRequest(request)
    writeRequest(request, to: dir)
    span.attributes["http.payload.request_path"] = "\(relativeDir)/request.txt"

    let sseResponse: SSEResponse
    do {
      sseResponse = try await underlying.sse(for: request)
    } catch {
      span.recordError(error)
      span.setStatus(.init(code: .error, message: "\(error)"))
      span.end()
      throw error
    }

    span.attributes["http.status_code"] = sseResponse.response.statusCode
    setHeaderAttributes(sseResponse.response.headers, prefix: "http.response.header", on: span)

    let statusCode = sseResponse.response.statusCode
    let responseHeaders = sseResponse.response.headers

    let wrappedEvents = AsyncThrowingStream<SSEMessage, any Error> { continuation in
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
          span.attributes["http.payload.response_path"] = "\(relativeDir)/response.txt"

          continuation.finish()
          span.end()
        } catch {
          self?.writeSSEResponse(
            response: HTTPResponse(statusCode: statusCode, headers: responseHeaders),
            events: captured,
            to: dir,
            error: error,
          )
          span.attributes["http.payload.response_path"] = "\(relativeDir)/response.txt"

          span.recordError(error)
          span.setStatus(.init(code: .error, message: "\(error)"))
          span.end()

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

    return SSEResponse(response: sseResponse.response, events: wrappedEvents)
  }

  // MARK: - Shared span + directory setup

  /// Create the payload directory and start an `http.request` span.
  /// Shared by both `data(for:)` and `sse(for:)`.
  private func beginRequest(_ request: HTTPRequest) -> (dir: URL, relativeDir: String, span: any Span) {
    let requestID = ServiceContext.current?.llmCallID ?? UUID().uuidString.lowercased()
    let dir = directoryURL(base: baseDir, for: requestID, at: Date())
    let relativeDir = relativePath(of: dir)

    let span = startSpan("http.request", ofKind: .client)
    span.attributes["http.method"] = request.method
    span.attributes["http.url"] = request.url.absoluteString
    setHeaderAttributes(request.headers, prefix: "http.request.header", on: span)

    return (dir, relativeDir, span)
  }

  // MARK: - Directory layout

  /// `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
  private func directoryURL(base: URL, for requestID: String, at date: Date) -> URL {
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
    let year = String(format: "%04d", comps.year ?? 0)
    let month = String(format: "%02d", comps.month ?? 0)
    let day = String(format: "%02d", comps.day ?? 0)
    let hour = String(format: "%02d", comps.hour ?? 0)

    return base
      .appendingPathComponent(year)
      .appendingPathComponent(month)
      .appendingPathComponent(day)
      .appendingPathComponent(hour)
      .appendingPathComponent(requestID)
  }

  /// Relative path from `baseDir` to the given directory URL.
  private func relativePath(of dir: URL) -> String {
    let basePath = baseDir.standardizedFileURL.path
    let dirPath = dir.standardizedFileURL.path
    var relative = String(dirPath.dropFirst(basePath.count))
    if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
    if relative.hasSuffix("/") { relative = String(relative.dropLast()) }
    return relative
  }

  // MARK: - Request logging

  private func writeRequest(_ request: HTTPRequest, to dir: URL) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      var lines: [String] = []
      lines.append("\(request.method) \(request.url.absoluteString)")
      lines.append("")

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

  /// Set non-secret headers as span attributes.
  /// Header names are normalized: lowercased, dashes become underscores.
  private func setHeaderAttributes(
    _ headers: [String: [String]],
    prefix: String,
    on span: any Span,
  ) {
    for (name, values) in headers {
      guard !Self.sensitiveHeaders.contains(name.lowercased()) else { continue }
      let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: "_")
      let key = "\(prefix).\(normalizedName)"
      span.attributes[key] = values.joined(separator: ", ")
    }
  }
}
