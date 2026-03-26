import Fetch
import FetchSSE
import Foundation
import Testing
import WuhuAI
@testable import WuhuCore

struct LoggingHTTPTransportTests {
  @Test func data_logsRedactedRequestAndResponseBody() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let transport = LoggingHTTPTransport(
      underlying: MockFetchClient { request in
        #expect(request.method.rawValue == "POST")
        #expect(headerValues(request.headers, named: "Authorization") == ["Bearer secret-token"])

        let payload = try JSONSerialization.jsonObject(with: #require(try await bodyData(request))) as? [String: String]
        #expect(payload?["prompt"] == "hi")

        let responseBody = try JSONEncoder().encode(["status": "ok"])
        return jsonResponse(responseBody, status: 201)
      }.client,
      baseDir: baseDir,
    )

    var request = try Request(
      url: #require(URL(string: "https://example.com/v1/chat")),
      method: "POST",
      headers: [
        "Authorization": ["Bearer secret-token"],
        "Content-Type": ["application/json"],
      ],
      body: JSONEncoder().encode(["prompt": "hi"]),
    )
    request.addHeader("text/plain", for: "Accept")

    let response = try await transport(request)
    let payload = try await JSONSerialization.jsonObject(with: response.data()) as? [String: String]

    #expect(response.status.code == 201)
    #expect(payload?["status"] == "ok")

    let files = try payloadFiles(in: baseDir)
    let requestText = try String(contentsOf: files.request, encoding: .utf8).lowercased()
    let responseText = try String(contentsOf: files.response, encoding: .utf8).lowercased()

    #expect(requestText.contains("post https://example.com/v1/chat"))
    #expect(requestText.contains("authorization: [redacted]"))
    #expect(requestText.contains("\"prompt\""))
    #expect(responseText.contains("http 201"))
    #expect(responseText.contains("content-type: application/json"))
    #expect(responseText.contains("\"status\""))
  }

  @Test func sse_logsEventsAfterStreamCompletes() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let expected: [SSEEvent] = [
      .init(data: "hello"),
      .init(data: "world"),
    ]

    let transport = LoggingHTTPTransport(
      underlying: MockFetchClient { _ in
        sseResponse(expected)
      }.client,
      baseDir: baseDir,
    )

    let response = try await transport(Request(url: #require(URL(string: "https://example.com/stream")), method: "GET"))

    var received: [SSEEvent] = []
    for try await event in response.sse() {
      received.append(event)
    }

    #expect(received == expected)

    let files = try payloadFiles(in: baseDir)
    let responseText = try String(contentsOf: files.response, encoding: .utf8).lowercased()

    #expect(responseText.contains("http 200"))
    #expect(responseText.contains("content-type: text/event-stream"))
    #expect(responseText.contains("data: hello"))
    #expect(responseText.contains("data: world"))
    #expect(!responseText.contains("--- error ---"))
  }

  @Test func sse_cancellationLogsPartialTranscriptAndCancelsUpstream() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let probe = CancellationProbe()
    let firstEvent = SeenProbe()

    let transport = LoggingHTTPTransport(
      underlying: MockFetchClient { _ in
        var headers = Headers()
        headers[.contentType] = "text/event-stream"

        let body = Body.stream(contentType: "text/event-stream") {
          AsyncThrowingStream<Bytes, Error> { continuation in
            let producer = Task {
              continuation.yield(Array(serializeSSEEvent(.init(data: "first")).utf8))
              do {
                try await Task.sleep(for: .seconds(60))
                continuation.yield(Array(serializeSSEEvent(.init(data: "second")).utf8))
                continuation.finish()
              } catch {
                continuation.finish()
              }
            }

            continuation.onTermination = { _ in
              producer.cancel()
              Task {
                await probe.markCancelled()
              }
            }
          }
        }

        return Response(status: Status(code: 200), headers: headers, body: body)
      }.client,
      baseDir: baseDir,
    )

    var response: Response? = try await transport(
      Request(url: #require(URL(string: "https://example.com/cancel")), method: "GET"),
    )
    let activeResponse = try #require(response)

    let consumer = Task {
      do {
        for try await chunk in activeResponse.body.asyncBytes() {
          #expect(String(decoding: chunk, as: UTF8.self).contains("data: first"))
          await firstEvent.markSeen()
        }
      } catch is CancellationError {}
    }

    try await waitUntil {
      await firstEvent.wasSeen()
    }

    consumer.cancel()
    _ = await consumer.result

    response = nil

    try await waitUntil {
      await probe.wasCancelled()
    }

    let responseURL = try await waitForPayloadFile(named: "response.txt", in: baseDir)
    let responseText = try String(contentsOf: responseURL, encoding: .utf8).lowercased()

    #expect(responseText.contains("data: first"))
    #expect(!responseText.contains("data: second"))
    #expect(responseText.contains("--- error ---"))
  }
}

private struct MockFetchClient {
  var handler: @Sendable (Request) async throws -> Response

  var client: FetchClient {
    FetchClient(fetch: handler)
  }
}

private actor CancellationProbe {
  private var cancelled = false

  func markCancelled() {
    cancelled = true
  }

  func wasCancelled() -> Bool {
    cancelled
  }
}

private actor SeenProbe {
  private var seen = false

  func markSeen() {
    seen = true
  }

  func wasSeen() -> Bool {
    seen
  }
}

private func jsonResponse(_ data: Data, status: Int = 200) -> Response {
  var headers = Headers()
  headers[.contentType] = "application/json"
  return Response(
    status: Status(code: status),
    headers: headers,
    body: .chunk(Array(data)),
  )
}

private func sseResponse(_ events: [SSEEvent], status: Int = 200) -> Response {
  var headers = Headers()
  headers[.contentType] = "text/event-stream"
  let payload = events.map(serializeSSEEvent).joined()
  return Response(
    status: Status(code: status),
    headers: headers,
    body: .chunk(Array(payload.utf8)),
  )
}

private func serializeSSEEvent(_ event: SSEEvent) -> String {
  var lines: [String] = []

  if event.event != "message" {
    lines.append("event: \(event.event)")
  }
  if let id = event.id {
    lines.append("id: \(id)")
  }
  if let retry = event.retry {
    lines.append("retry: \(retry)")
  }

  let dataLines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
  if dataLines.isEmpty {
    lines.append("data:")
  } else {
    for line in dataLines {
      lines.append("data: \(line)")
    }
  }

  return lines.joined(separator: "\n") + "\n\n"
}

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("LoggingHTTPTransportTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func payloadFiles(in baseDir: URL) throws -> (request: URL, response: URL) {
  let request = try #require(findPayloadFile(named: "request.txt", in: baseDir))
  let response = try #require(findPayloadFile(named: "response.txt", in: baseDir))
  return (request, response)
}

private func findPayloadFile(named name: String, in baseDir: URL) -> URL? {
  FileManager.default.enumerator(at: baseDir, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }
    .first { $0.lastPathComponent == name }
}

private func waitForPayloadFile(named name: String, in baseDir: URL) async throws -> URL {
  try await waitUntilResult {
    findPayloadFile(named: name, in: baseDir)
  }
}

private func waitUntil(
  timeoutSeconds: Double = 2,
  operation: @escaping @Sendable () async -> Bool,
) async throws {
  _ = try await waitUntilResult(timeoutSeconds: timeoutSeconds) {
    if await operation() {
      return true
    }
    return nil
  }
}

private func waitUntilResult<T>(
  timeoutSeconds: Double = 2,
  operation: @escaping @Sendable () async -> T?,
) async throws -> T {
  let deadline = Date().addingTimeInterval(timeoutSeconds)

  while Date() < deadline {
    if let value = await operation() {
      return value
    }
    try await Task.sleep(for: .milliseconds(25))
  }

  throw CancellationError()
}
