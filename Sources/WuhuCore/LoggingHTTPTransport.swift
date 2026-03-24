import Fetch
import Foundation
import ServiceContextModule
import Tracing

/// A `FetchClient` wrapper that logs raw HTTP requests and responses to disk,
/// and creates an `http.request` tracing span for each call.
///
/// For each request, creates a directory at:
///   `<baseDir>/<year>/<month>/<day>/<hour>/<requestID>/`
/// containing `request.txt` (headers + body) and `response.txt` (headers + body).
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
public struct LoggingHTTPTransport: Sendable {
  private let underlying: FetchClient
  private let baseDir: URL

  private static let sensitiveHeaders: Set<String> = ["authorization", "x-api-key"]

  public init(underlying: FetchClient, baseDir: URL) {
    self.underlying = underlying
    self.baseDir = baseDir
  }

  public var client: FetchClient {
    FetchClient(fetch: self.callAsFunction)
  }

  public func callAsFunction(_ request: Request) async throws -> Response {
    let (dir, relativeDir, span) = beginRequest(request)
    let (materializedRequest, requestBody) = try await materialize(request)
    writeRequest(materializedRequest, body: requestBody, to: dir)
    span.attributes["http.payload.request_path"] = "\(relativeDir)/request.txt"

    let response: Response
    do {
      response = try await underlying(materializedRequest)
    } catch {
      span.recordError(error)
      span.setStatus(.init(code: .error, message: "\(error)"))
      span.end()
      throw error
    }

    span.attributes["http.status_code"] = response.status.code
    setHeaderAttributes(response.headers, prefix: "http.response.header", on: span)

    let wrappedBody = BodyStream { continuation in
      let task = Task {
        var captured: Bytes = []
        var terminalError: (any Error)?

        defer {
          writeResponse(
            response: Response(status: response.status, headers: response.headers),
            body: Data(captured),
            to: dir,
            error: terminalError,
          )
          span.attributes["http.payload.response_path"] = "\(relativeDir)/response.txt"

          if let terminalError {
            span.recordError(terminalError)
            span.setStatus(.init(code: .error, message: "\(terminalError)"))
          }

          span.end()
        }

        do {
          for try await chunk in response.body {
            captured.append(contentsOf: chunk)
            switch continuation.yield(chunk) {
            case .enqueued, .dropped:
              continue
            case .terminated:
              terminalError = CancellationError()
              return
            @unknown default:
              continue
            }
          }
          continuation.finish()

          if Task.isCancelled {
            terminalError = CancellationError()
          }
        } catch {
          terminalError = error

          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }

      continuation.onTermination = { termination in
        guard case .cancelled = termination else { return }
        task.cancel()
      }
    }

    return Response(
      status: response.status,
      headers: response.headers,
      body: wrappedBody,
    )
  }

  private func beginRequest(_ request: Request) -> (dir: URL, relativeDir: String, span: any Span) {
    let context = ServiceContext.current ?? .topLevel
    let requestID = context.llmCallID ?? UUID().uuidString.lowercased()
    let dir = directoryURL(base: baseDir, for: requestID, at: Date())
    let relativeDir = relativePath(of: dir)

    let span = startSpan("http.request", context: context, ofKind: .client)
    span.attributes["http.method"] = request.method.rawValue
    span.attributes["http.url"] = request.url.absoluteString
    setHeaderAttributes(request.headers, prefix: "http.request.header", on: span)

    return (dir, relativeDir, span)
  }

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

  private func relativePath(of dir: URL) -> String {
    let basePath = baseDir.standardizedFileURL.path
    let dirPath = dir.standardizedFileURL.path
    var relative = String(dirPath.dropFirst(basePath.count))
    if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
    if relative.hasSuffix("/") { relative = String(relative.dropLast()) }
    return relative
  }

  private func writeRequest(_ request: Request, body: Data?, to dir: URL) {
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      var lines: [String] = []
      lines.append("\(request.method.rawValue) \(request.url.absoluteString)")
      lines.append("")

      let sortedHeaders = request.headers.sorted {
        $0.name.rawName.lowercased() < $1.name.rawName.lowercased()
      }
      for header in sortedHeaders {
        let name = header.name.rawName
        if Self.sensitiveHeaders.contains(name.lowercased()) {
          lines.append("\(name): [REDACTED]")
        } else {
          lines.append("\(name): \(header.value)")
        }
      }

      lines.append("")

      if let body {
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

  private func writeResponse(
    response: Response,
    body: Data,
    to dir: URL,
    error: (any Error)? = nil,
  ) {
    do {
      var lines: [String] = []
      lines.append("HTTP \(response.status.code)")
      lines.append("")

      let sortedHeaders = response.headers.sorted {
        $0.name.rawName.lowercased() < $1.name.rawName.lowercased()
      }
      for header in sortedHeaders {
        lines.append("\(header.name.rawName): \(header.value)")
      }

      lines.append("")

      if let json = try? JSONSerialization.jsonObject(with: body),
         let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      {
        lines.append(String(decoding: pretty, as: UTF8.self))
      } else {
        lines.append(String(decoding: body, as: UTF8.self))
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

  private func setHeaderAttributes(
    _ headers: Headers,
    prefix: String,
    on span: any Span,
  ) {
    for header in headers {
      let name = header.name.rawName
      guard !Self.sensitiveHeaders.contains(name.lowercased()) else { continue }
      let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: "_")
      span.attributes["\(prefix).\(normalizedName)"] = header.value
    }
  }

  private func materialize(_ request: Request) async throws -> (Request, Data?) {
    guard let body = request.body else { return (request, nil) }

    var bytes: Bytes = []
    for try await chunk in body.stream {
      bytes.append(contentsOf: chunk)
    }

    var copy = request
    copy.body = .bytes(bytes, contentType: body.contentType)
    return (copy, Data(bytes))
  }
}
