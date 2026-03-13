import Foundation
import PiAI
import ServiceContextModule
import Tracing

/// An `HTTPClient` wrapper that creates an `http.request` child span and
/// captures raw HTTP request/response payloads to an ``LLMPayloadStore``.
///
/// For each SSE call:
/// - Creates an `http.request` child span with URL, method, status, headers
/// - Writes request/response payloads to the store keyed by
///   `{datePath}/{callID}.request` and `{datePath}/{callID}.response`
///
/// File paths are derived from ``ServiceContext/llmCallID`` and
/// ``ServiceContext/llmCallDatePath`` set by ``tracedStreamFn``.
///
/// Sensitive headers (`authorization`, `x-api-key`) are stripped from span
/// attributes and payload files.
public final class LoggingHTTPTransport: PiAI.HTTPClient, @unchecked Sendable {
  private let underlying: any PiAI.HTTPClient
  private let payloadStore: (any LLMPayloadStore)?

  private static let sensitiveHeaders: Set<String> = ["authorization", "x-api-key"]

  public init(underlying: any PiAI.HTTPClient, payloadStore: (any LLMPayloadStore)? = nil) {
    self.underlying = underlying
    self.payloadStore = payloadStore
  }

  // MARK: - HTTPClient conformance

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    // Non-streaming calls — pass through (not used for LLM inference).
    try await underlying.data(for: request)
  }

  public func sse(for request: HTTPRequest) async throws -> SSEResponse {
    let ctx = ServiceContext.current
    let callID = ctx?.llmCallID
    let datePath = ctx?.llmCallDatePath

    // Start HTTP span manually — we end it when the SSE stream completes.
    let span = startSpan("http.request", ofKind: .client)
    span.attributes["http.method"] = request.method
    span.attributes["http.url"] = request.url.absoluteString
    setHeaderAttributes(request.headers, prefix: "http.request.header", on: span)

    // Write request payload immediately (before the stream starts).
    if let callID, let datePath, let store = payloadStore {
      let requestPath = "\(datePath)/\(callID).request"
      let requestData = serializeRequest(request)
      do {
        try await store.write(path: requestPath, data: requestData)
      } catch {
        // Best-effort: payload capture must never break the LLM call.
      }
    }

    let sseResponse: SSEResponse
    do {
      sseResponse = try await underlying.sse(for: request)
    } catch {
      span.recordError(error)
      span.setStatus(.init(code: .error, message: "\(error)"))
      span.end()
      throw error
    }

    // Set response attributes on span.
    span.attributes["http.status_code"] = sseResponse.response.statusCode
    setHeaderAttributes(sseResponse.response.headers, prefix: "http.response.header", on: span)

    let responsePath = (callID != nil && datePath != nil) ? "\(datePath!)/\(callID!).response" : nil
    let store = payloadStore

    // Build a metadata header for the response file.
    let metaHeader: Data = {
      var header = Data()
      header.append(Data("HTTP \(sseResponse.response.statusCode)\n".utf8))
      for (name, values) in sseResponse.response.headers.sorted(by: { $0.key < $1.key }) {
        guard !Self.sensitiveHeaders.contains(name.lowercased()) else { continue }
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

          // Stream completed — write response payload.
          if let responsePath, let store {
            do {
              try await store.write(path: responsePath, data: buffer)
            } catch {
              // Best-effort.
            }
          }

          continuation.finish()
          span.end()
        } catch {
          // Stream failed — still write what we captured.
          buffer.append(Data("\n--- ERROR ---\n\(error)\n".utf8))
          if let responsePath, let store {
            do {
              try await store.write(path: responsePath, data: buffer)
            } catch {
              // Best-effort.
            }
          }

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

  // MARK: - Private

  /// Serialize an HTTP request into the payload format:
  /// method + URL, non-secret headers, blank line, pretty-printed JSON body.
  private func serializeRequest(_ request: HTTPRequest) -> Data {
    var data = Data()
    data.append(Data("\(request.method) \(request.url.absoluteString)\n".utf8))

    let sortedHeaders = request.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
    for (name, values) in sortedHeaders {
      if Self.sensitiveHeaders.contains(name.lowercased()) {
        data.append(Data("\(name): [REDACTED]\n".utf8))
      } else {
        for value in values {
          data.append(Data("\(name): \(value)\n".utf8))
        }
      }
    }

    data.append(Data("\n".utf8))

    if let body = request.body {
      if let json = try? JSONSerialization.jsonObject(with: body),
         let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      {
        data.append(pretty)
      } else {
        data.append(body)
      }
    }

    return data
  }

  /// Set non-secret headers as span attributes.
  /// Header names are normalized: lowercased, dashes become underscores.
  private func setHeaderAttributes(
    _ headers: [String: [String]],
    prefix: String,
    on span: any Span
  ) {
    for (name, values) in headers {
      guard !Self.sensitiveHeaders.contains(name.lowercased()) else { continue }
      let normalizedName = name.lowercased().replacingOccurrences(of: "-", with: "_")
      let key = "\(prefix).\(normalizedName)"
      span.attributes[key] = values.joined(separator: ", ")
    }
  }
}
