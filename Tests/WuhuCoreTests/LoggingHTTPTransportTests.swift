import Foundation
import PiAI
import Testing
@testable import WuhuCore

struct LoggingHTTPTransportTests {
  @Test func data_logsRedactedRequestAndResponseBody() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let transport = LoggingHTTPTransport(
      underlying: LoggingHTTPClientMock(
        dataHandler: { request in
          #expect(request.method == "POST")
          #expect(request.headers["Authorization"] == ["Bearer secret-token"])

          let body = try #require(request.body)
          let payload = try JSONSerialization.jsonObject(with: body) as? [String: String]
          #expect(payload?["prompt"] == "hi")

          let responseBody = try JSONEncoder().encode(["status": "ok"])
          return (
            responseBody,
            HTTPResponse(statusCode: 201, headers: ["Content-Type": ["application/json"]]),
          )
        },
      ),
      baseDir: baseDir,
    )

    var request = try HTTPRequest(
      url: #require(URL(string: "https://example.com/v1/chat")),
      method: "POST",
      headers: [
        "Authorization": ["Bearer secret-token"],
        "Content-Type": ["application/json"],
      ],
      body: JSONEncoder().encode(["prompt": "hi"]),
    )
    request.addHeader("text/plain", for: "Accept")

    let (data, response) = try await transport.data(for: request)
    let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]

    #expect(response.statusCode == 201)
    #expect(payload?["status"] == "ok")

    let files = try payloadFiles(in: baseDir)
    let requestText = try String(contentsOf: files.request, encoding: .utf8)
    let responseText = try String(contentsOf: files.response, encoding: .utf8)

    #expect(requestText.contains("POST https://example.com/v1/chat"))
    #expect(requestText.contains("Authorization: [REDACTED]"))
    #expect(requestText.contains("\"prompt\""))
    #expect(responseText.contains("HTTP 201"))
    #expect(responseText.contains("Content-Type: application/json"))
    #expect(responseText.contains("\"status\""))
  }

  @Test func sse_logsEventsAfterStreamCompletes() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let expected: [SSEMessage] = [
      .init(event: "message", data: "hello"),
      .init(data: "world"),
    ]

    let transport = LoggingHTTPTransport(
      underlying: LoggingHTTPClientMock(
        sseHandler: { _ in
          let events = AsyncThrowingStream<SSEMessage, any Error> { continuation in
            for event in expected {
              continuation.yield(event)
            }
            continuation.finish()
          }
          return SSEResponse(
            response: HTTPResponse(statusCode: 200, headers: ["Content-Type": ["text/event-stream"]]),
            events: events,
          )
        },
      ),
      baseDir: baseDir,
    )

    let response = try await transport.sse(for: HTTPRequest(url: #require(URL(string: "https://example.com/stream"))))

    var received: [SSEMessage] = []
    for try await event in response.events {
      received.append(event)
    }

    #expect(received == expected)

    let files = try payloadFiles(in: baseDir)
    let responseText = try String(contentsOf: files.response, encoding: .utf8)

    #expect(responseText.contains("HTTP 200"))
    #expect(responseText.contains("--- SSE Events (2) ---"))
    #expect(responseText.contains("event: message"))
    #expect(responseText.contains("data: hello"))
    #expect(responseText.contains("data: world"))
    #expect(!responseText.contains("--- Error ---"))
  }

  @Test func sse_cancellationLogsPartialTranscriptAndCancelsUpstream() async throws {
    let baseDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let probe = CancellationProbe()

    let transport = LoggingHTTPTransport(
      underlying: LoggingHTTPClientMock(
        sseHandler: { _ in
          let events = AsyncThrowingStream<SSEMessage, any Error> { continuation in
            let producer = Task {
              continuation.yield(.init(data: "first"))
              do {
                try await Task.sleep(for: .seconds(60))
                continuation.yield(.init(data: "second"))
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

          return SSEResponse(response: HTTPResponse(statusCode: 200), events: events)
        },
      ),
      baseDir: baseDir,
    )

    var response: SSEResponse? = try await transport.sse(
      for: HTTPRequest(url: #require(URL(string: "https://example.com/cancel"))),
    )

    do {
      let events = try #require(response).events
      try await Task {
        for try await event in events {
          #expect(event.data == "first")
          break
        }
      }.value
    }

    response = nil

    try await waitUntil {
      await probe.wasCancelled()
    }

    let responseURL = try await waitForPayloadFile(named: "response.txt", in: baseDir)
    let responseText = try String(contentsOf: responseURL, encoding: .utf8)

    #expect(responseText.contains("--- SSE Events (1) ---"))
    #expect(responseText.contains("data: first"))
    #expect(!responseText.contains("data: second"))
    #expect(responseText.contains("--- Error ---"))
  }
}

private struct LoggingHTTPClientMock: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?
  var sseHandler: (@Sendable (HTTPRequest) async throws -> SSEResponse)?

  init(
    dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))? = nil,
    sseHandler: (@Sendable (HTTPRequest) async throws -> SSEResponse)? = nil,
  ) {
    self.dataHandler = dataHandler
    self.sseHandler = sseHandler
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard let dataHandler else {
      throw PiAIError.unsupported("LoggingHTTPClientMock.dataHandler not set")
    }
    return try await dataHandler(request)
  }

  func sse(for request: HTTPRequest) async throws -> SSEResponse {
    guard let sseHandler else {
      throw PiAIError.unsupported("LoggingHTTPClientMock.sseHandler not set")
    }
    return try await sseHandler(request)
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

  throw TimeoutError()
}

private struct TimeoutError: Error {}
