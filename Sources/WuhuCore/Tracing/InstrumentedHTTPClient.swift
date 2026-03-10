import Foundation
import PiAI
import ServiceContextModule

/// Header names that must never be written to payload files.
private let secretHeaderNames: Set<String> = [
  "authorization",
  "x-api-key",
  "api-key",
]

/// Wraps a `PiAI.HTTPClient` to capture raw HTTP request/response bytes.
///
/// For each SSE call, writes two files to the payload store:
/// - `{date}/{callID}.request` — HTTP method, URL, non-secret headers, and raw JSON body
/// - `{date}/{callID}.response` — HTTP status, response headers, and raw SSE event text
///
/// File paths are derived from ``LLMCallIDKey`` and ``LLMCallDatePathKey``
/// set in `ServiceContext` by ``tracedStreamFn``.
///
/// The request file is written immediately before the stream starts.
/// The response file is written after the stream completes (or fails).
/// If the call crashes mid-stream, you still have the request for debugging.
public struct InstrumentedHTTPClient: PiAI.HTTPClient, Sendable {
  private let base: any PiAI.HTTPClient
  private let payloadStore: any LLMPayloadStore

  public init(base: any PiAI.HTTPClient, payloadStore: any LLMPayloadStore) {
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

    // Write request immediately (before the stream starts)
    if let callID, let datePath {
      let requestPath = "\(datePath)/\(callID).request"
      let requestData = serializeRequest(request)
      do {
        try await payloadStore.write(path: requestPath, data: requestData)
      } catch {
        // Best-effort: payload capture must never break the LLM call
      }
    }

    let sseResponse = try await base.sse(for: request)

    // If we don't have a call ID, we can't write files — just pass through
    guard let callID, let datePath else {
      return sseResponse
    }

    // Wrap the SSE stream to accumulate raw response text
    let responsePath = "\(datePath)/\(callID).response"
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

          // Stream completed — write response
          do {
            try await store.write(path: responsePath, data: buffer)
          } catch {
            // Best-effort
          }

          continuation.finish()
        } catch {
          // Stream failed — still write what we captured
          buffer.append(Data("\n--- ERROR ---\n\(error)\n".utf8))
          do {
            try await store.write(path: responsePath, data: buffer)
          } catch {
            // Best-effort
          }
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
}
