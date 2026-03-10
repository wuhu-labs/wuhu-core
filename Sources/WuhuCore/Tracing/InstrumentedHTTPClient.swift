import Foundation
import PiAI
import ServiceContextModule
import Tracing

/// Header names that must never be written to payload files or span attributes.
private let secretHeaderNames: Set<String> = [
  "authorization",
  "x-api-key",
]

/// Wraps a `PiAI.HTTPClient` to capture raw HTTP request/response bytes and
/// create an OTel child span for HTTP-level observability.
///
/// For each SSE call:
/// - Creates an `http.request` child span with URL, method, status, headers
/// - Writes two files to the payload store:
///   - `{date}/{callID}.request` — HTTP method, URL, non-secret headers, raw JSON body
///   - `{date}/{callID}.response` — HTTP status, response headers, raw SSE event text
///
/// File paths are derived from ``LLMCallIDKey`` and ``LLMCallDatePathKey``
/// set in `ServiceContext` by ``tracedStreamFn``.
///
/// The request file is written immediately before the stream starts.
/// The response file is written after the stream completes (or fails).
/// If the call crashes mid-stream, you still have the request for debugging.
public struct InstrumentedHTTPClient: PiAI.HTTPClient, Sendable {
  private let base: any PiAI.HTTPClient
  private let payloadStore: any DataBucket

  public init(base: any PiAI.HTTPClient, payloadStore: any DataBucket) {
    self.base = base
    self.payloadStore = payloadStore
  }

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    // Non-streaming calls — pass through (not used for LLM inference)
    try await base.data(for: request)
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let ctx = ServiceContext.current
    let callID = ctx?.llmCallID
    let datePath = ctx?.llmCallDatePath

    // Start HTTP span manually — we end it when the SSE stream completes,
    // not when this function returns, because the stream outlives the scope.
    let span = startSpan("http.request", ofKind: .client)

    // Set request attributes on span
    span.attributes["http.method"] = request.method
    span.attributes["http.url"] = request.url.absoluteString
    setHeaderAttributes(request.headers, prefix: "http.request.header", on: span)

    // Write request payload immediately (before the stream starts)
    if let callID, let datePath {
      let requestPath = "\(datePath)/\(callID).request"
      let requestData = serializeRequest(request)
      do {
        try await payloadStore.write(key: requestPath, data: requestData)
      } catch {
        // Best-effort: payload capture must never break the LLM call
      }
    }

    let sseResponse: SSEResponse
    do {
      sseResponse = try await base.sse(for: request)
    } catch {
      span.recordError(error)
      span.setStatus(.init(code: .error, message: "\(error)"))
      span.end()
      throw error
    }

    // Set response attributes on span
    span.attributes["http.status_code"] = sseResponse.response.statusCode
    setHeaderAttributes(sseResponse.response.headers, prefix: "http.response.header", on: span)

    // If we don't have a call ID, we can't write files — just pass through
    // but still wrap to end the span when stream completes
    let responsePath = (callID != nil && datePath != nil) ? "\(datePath!)/\(callID!).response" : nil
    let store = payloadStore

    // Build a metadata header for the response file
    let metaHeader: Data = {
      var header = Data()
      header.append(Data("HTTP \(sseResponse.response.statusCode)\n".utf8))
      for (name, values) in sseResponse.response.headers.sorted(by: { $0.key < $1.key }) {
        guard !secretHeaderNames.contains(name.lowercased()) else { continue }
        for value in values {
          header.append(Data("\(name): \(value)\n".utf8))
        }
      }
      header.append(Data("\n".utf8))
      return header
    }()

    let wrappedEvents = AsyncThrowingStream<SSEMessage, any Error> { continuation in
      let task = Task {
        var buffer = metaHeader
        buffer.reserveCapacity(metaHeader.count + 8 * 1024)
        do {
          for try await event in sseResponse.events {
            if let eventType = event.event {
              buffer.append(Data("event: \(eventType)\n".utf8))
            }
            buffer.append(Data("data: \(event.data)\n\n".utf8))

            continuation.yield(event)
          }

          // Stream completed successfully — write response payload
          if let responsePath {
            do {
              try await store.write(key: responsePath, data: buffer)
            } catch {
              // Best-effort
            }
          }

          continuation.finish()
          span.end()
        } catch {
          // Stream failed — still write what we captured
          buffer.append(Data("\n--- ERROR ---\n\(error)\n".utf8))
          if let responsePath {
            do {
              try await store.write(key: responsePath, data: buffer)
            } catch {
              // Best-effort
            }
          }

          span.recordError(error)
          span.setStatus(.init(code: .error, message: "\(error)"))
          span.end()

          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }

    return SSEResponse(response: sseResponse.response, events: wrappedEvents)
  }

  // MARK: - Private

  /// Serialize an HTTP request into the payload format:
  /// method + URL, non-secret headers, blank line, raw body.
  private func serializeRequest(_ request: HTTPRequest) -> Data {
    var data = Data()
    data.append(Data("\(request.method) \(request.url.absoluteString)\n".utf8))
    for (name, values) in request.headers.sorted(by: { $0.key < $1.key }) {
      guard !secretHeaderNames.contains(name.lowercased()) else { continue }
      for value in values {
        data.append(Data("\(name): \(value)\n".utf8))
      }
    }
    data.append(Data("\n".utf8))
    if let body = request.body {
      data.append(body)
    }
    return data
  }

  /// Set non-secret headers as span attributes.
  /// Header names are normalized: lowercased, dashes become underscores.
  private func setHeaderAttributes(
    _ headers: [String: [String]],
    prefix: String,
    on span: any Span,
  ) {
    for (name, values) in headers {
      guard !secretHeaderNames.contains(name.lowercased()) else { continue }
      let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: "_")
      let key = "\(prefix).\(normalizedName)"
      span.attributes[key] = values.joined(separator: ", ")
    }
  }
}
