import Fetch
import FetchSSE
import Foundation
import Testing
import WuhuAI
import WuhuAPI
import WuhuClient
import WuhuCoreClient

struct WuhuClientTests {
  @Test func listMountTemplatesDecodesResponse() async throws {
    let http = MockFetchClient { request in
      #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/mount-templates")
      #expect(request.method.rawValue == "GET")
      let now = Date(timeIntervalSince1970: 0)
      let data = try WuhuJSON.encoder.encode(
        [
          WuhuMountTemplate(
            id: "mt1",
            name: "template",
            type: .folder,
            templatePath: "/tmp/template",
            workspacesPath: "/tmp/workspaces",
            startupScript: "./startup.sh",
            createdAt: now,
            updatedAt: now,
          ),
        ] as [WuhuMountTemplate],
      )
      return jsonResponse(data)
    }

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), fetch: http.client)
    let templates = try await client.listMountTemplates()
    #expect(templates.map(\.name) == ["template"])
    #expect(templates.map(\.type.rawValue) == ["folder"])
  }

  @Test func promptStreamDecodesSSEEvents() async throws {
    actor Counter {
      var n = 0
      func next() -> Int {
        n += 1
        return n
      }
    }
    let counter = Counter()

    let http = MockFetchClient { request in
      switch await counter.next() {
      case 1:
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1")
        #expect(request.method.rawValue == "GET")

        let now = Date(timeIntervalSince1970: 0)
        let baseline = WuhuGetSessionResponse(
          session: WuhuSession(
            id: "s1",
            provider: .openai,
            model: "m",
            cwd: "/tmp",
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            headEntryID: 1,
            tailEntryID: 1,
          ),
          transcript: [
            WuhuSessionEntry(
              id: 1,
              sessionID: "s1",
              parentEntryID: nil,
              createdAt: now,
              payload: .message(.user(.init(
                user: "unknown_user",
                content: [.text(text: "baseline", signature: nil)],
                timestamp: now,
              ))),
            ),
          ],
          inProcessExecution: .init(activePromptCount: 0),
        )
        return try jsonResponse(WuhuJSON.encoder.encode(baseline))

      case 2:
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/enqueue?lane=followUp")
        #expect(request.method.rawValue == "POST")

        let body = try #require(try await bodyData(request))
        let decoded = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: body)
        #expect(decoded.author == .unknown)
        #expect(decoded.content == .text("hello"))

        return try jsonResponse(WuhuJSON.encoder.encode(QueueItemID(rawValue: "q1")))

      default:
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/follow?sinceCursor=1&stopAfterIdle=1")
        #expect(headerValues(request.headers, named: "Accept") == ["text/event-stream"])
        return sseResponse([
          .init(data: #"{"type":"assistant_text_delta","delta":"Hi"}"#),
          .init(data: #"{"type":"done"}"#),
        ])
      }
    }

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), fetch: http.client)
    let stream = try await client.promptStream(sessionID: "s1", input: "hello")

    var deltas: [String] = []
    var sawDone = false

    for try await event in stream {
      switch event {
      case let .assistantTextDelta(delta):
        deltas.append(delta)
      case .done:
        sawDone = true
      default:
        break
      }
    }

    #expect(deltas == ["Hi"])
    #expect(sawDone)
  }

  @Test func setSessionModelPostsAndDecodesResponse() async throws {
    let http = MockFetchClient { request in
      #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/model")
      #expect(request.method.rawValue == "POST")

      let session = WuhuSession(
        id: "s1",
        provider: .openai,
        model: "gpt-5.2-codex",
        cwd: "/tmp",
        parentSessionID: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        headEntryID: 1,
        tailEntryID: 2,
      )
      let response = WuhuSetSessionModelResponse(
        session: session,
        selection: .init(provider: .openai, model: "gpt-5.2-codex", reasoningEffort: .high),
        applied: true,
      )
      return try jsonResponse(WuhuJSON.encoder.encode(response))
    }

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), fetch: http.client)
    let response = try await client.setSessionModel(sessionID: "s1", provider: .openai, model: "gpt-5.2-codex", reasoningEffort: .high)
    #expect(response.applied == true)
    #expect(response.session.model == "gpt-5.2-codex")
  }

  @Test func followSessionStreamSetsAcceptHeaderAndDecodesEvents() async throws {
    let http = MockFetchClient { request in
      #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/follow")
      #expect(headerValues(request.headers, named: "Accept") == ["text/event-stream"])

      return sseResponse([
        .init(data: #"{"type":"idle"}"#),
        .init(data: #"{"type":"done"}"#),
      ])
    }

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), fetch: http.client)
    let stream = try await client.followSessionStream(sessionID: "s1")

    var sawIdle = false
    var sawDone = false

    for try await event in stream {
      switch event {
      case .idle:
        sawIdle = true
      case .done:
        sawDone = true
      default:
        break
      }
    }

    #expect(sawIdle)
    #expect(sawDone)
  }
}

private struct MockFetchClient {
  var handler: @Sendable (Request) async throws -> Response

  var client: FetchClient {
    FetchClient(fetch: handler)
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
