import Fetch
import FetchSSE
import Foundation
import Testing
import WuhuAI
import WuhuAPI
@testable import WuhuCoreClient

struct RemoteSessionSSETransportTests {
  @Test func subscribe_parsesInitialAndEvents() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let entry1 = WuhuSessionEntry(
      id: 1,
      sessionID: "s1",
      parentEntryID: nil,
      createdAt: Date(timeIntervalSince1970: 0),
      payload: .message(.user(.init(
        content: [.text(text: "hi", signature: nil)],
        timestamp: Date(timeIntervalSince1970: 0),
      ))),
    )

    let initialState = SessionInitialState(
      settings: .init(effectiveModel: .init(provider: .openai, id: "m")),
      status: .init(status: .idle),
      transcript: [entry1],
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )

    let appended = WuhuSessionEntry(
      id: 2,
      sessionID: "s1",
      parentEntryID: 1,
      createdAt: Date(timeIntervalSince1970: 1),
      payload: .message(.user(.init(
        content: [.text(text: "yo", signature: nil)],
        timestamp: Date(timeIntervalSince1970: 1),
      ))),
    )

    let frames: [SessionSubscriptionSSEFrame] = [
      .initial(initialState),
      .event(.transcriptAppended([appended])),
      .event(.statusUpdated(.init(status: .running))),
    ]

    let http = MockFetchClient { request in
      #expect(request.url.absoluteString.contains("/v1/sessions/s1/subscribe"))
      #expect(headerValues(request.headers, named: "Accept") == ["text/event-stream"])

      return sseResponse(frames.map { frame in
        let data = try! WuhuJSON.encoder.encode(frame)
        return .init(data: String(decoding: data, as: UTF8.self))
      })
    }

    let transport = RemoteSessionSSETransport(baseURL: baseURL, fetch: http.client, sleep: { _ in })
    let subscription = try await transport.subscribe(sessionID: .init(rawValue: "s1"), since: .init())

    #expect(subscription.initial == initialState)

    let received = try await Task {
      var it = subscription.events.makeAsyncIterator()
      var out: [SessionEvent] = []
      if let e1 = try await it.next() { out.append(e1) }
      if let e2 = try await it.next() { out.append(e2) }
      return out
    }.value

    #expect(received == [
      .transcriptAppended([appended]),
      .statusUpdated(.init(status: .running)),
    ])
  }

  @Test func subscribe_retriesWithExponentialBackoff_andEmitsConnectionStates() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let initialState = SessionInitialState(
      settings: .init(effectiveModel: .init(provider: .openai, id: "m")),
      status: .init(status: .idle),
      transcript: [],
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )

    actor Counter {
      var n = 0
      func next() -> Int {
        n += 1
        return n
      }
    }

    actor SleepRecorder {
      private var delays: [Double] = []

      func record(_ delay: Double) {
        delays.append(delay)
      }

      func values() -> [Double] {
        delays
      }
    }

    let counter = Counter()
    let sleeper = SleepRecorder()

    let http = MockFetchClient { _ in
      let attempt = await counter.next()
      if attempt <= 2 {
        throw URLError(.notConnectedToInternet)
      }

      let data = try! WuhuJSON.encoder.encode(SessionSubscriptionSSEFrame.initial(initialState))
      return sseResponse([.init(data: String(decoding: data, as: UTF8.self))])
    }

    let transport = RemoteSessionSSETransport(
      baseURL: baseURL,
      fetch: http.client,
      retryPolicy: .init(maxDelaySeconds: 30),
      sleep: { seconds in
        await sleeper.record(seconds)
      },
    )

    let result = try await transport.subscribeWithConnectionState(sessionID: .init(rawValue: "s1"), since: .init())
    #expect(result.subscription.initial == initialState)

    let states = await Task {
      var it = result.connectionStates.makeAsyncIterator()
      var out: [SSEConnectionState] = []
      while out.count < 6, let next = await it.next() {
        out.append(next)
        if next == .connected { break }
      }
      return out
    }.value

    #expect(states.first == .connecting)
    #expect(states.contains(.retrying(attempt: 1, delaySeconds: 0)))
    #expect(states.contains(.retrying(attempt: 2, delaySeconds: 1)))
    #expect(states.contains(.connected))

    let delays = await sleeper.values()
    #expect(delays == [1])
  }

  @Test func enqueue_sendsPOSTWithLaneQueryAndDecodesID() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let expectedID = QueueItemID(rawValue: "q1")

    let http = MockFetchClient { request in
      #expect(request.method.rawValue == "POST")
      #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/enqueue?lane=followUp")
      #expect(headerValues(request.headers, named: "Content-Type") == ["application/json"])

      let decoded = try WuhuJSON.decoder.decode(
        QueuedUserMessage.self,
        from: try #require(try await bodyData(request)),
      )
      #expect(decoded.author == .unknown)
      #expect(decoded.content == .text("hello"))

      return jsonResponse(try WuhuJSON.encoder.encode(expectedID))
    }

    let transport = RemoteSessionSSETransport(baseURL: baseURL, fetch: http.client)
    let id = try await transport.enqueue(
      sessionID: .init(rawValue: "s1"),
      message: .init(author: .unknown, content: .text("hello")),
      lane: .followUp,
    )

    #expect(id == expectedID)
  }

  @Test func cancel_sendsPOSTWithLaneQuery() async throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:5530"))

    let http = MockFetchClient { request in
      #expect(request.method.rawValue == "POST")
      #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/cancel?lane=steer")

      struct Body: Decodable { var id: QueueItemID }
      let decoded = try WuhuJSON.decoder.decode(
        Body.self,
        from: try #require(try await bodyData(request)),
      )
      #expect(decoded.id == .init(rawValue: "q1"))

      return jsonResponse(Data())
    }

    let transport = RemoteSessionSSETransport(baseURL: baseURL, fetch: http.client)
    try await transport.cancel(
      sessionID: .init(rawValue: "s1"),
      id: .init(rawValue: "q1"),
      lane: .steer,
    )
  }
}

private struct MockFetchClient {
  var handler: @Sendable (Request) async throws -> Response

  var client: FetchClient {
    FetchClient(fetch: self.handler)
  }
}

private func jsonResponse(_ data: Data, status: Int = 200) -> Response {
  var headers = Headers()
  headers[.contentType] = "application/json"
  return Response(
    status: Status(code: status),
    headers: headers,
    body: .chunk(Array(data))
  )
}

private func sseResponse(_ events: [SSEEvent], status: Int = 200) -> Response {
  var headers = Headers()
  headers[.contentType] = "text/event-stream"
  let payload = events.map(serializeSSEEvent).joined()
  return Response(
    status: Status(code: status),
    headers: headers,
    body: .chunk(Array(payload.utf8))
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
