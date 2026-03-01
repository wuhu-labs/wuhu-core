import Foundation
import PiAI
import Testing
import WuhuAPI
import WuhuClient
import WuhuCoreClient

struct WuhuClientTests {
  @Test func listMountTemplatesDecodesResponse() async throws {
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/mount-templates")
        #expect(request.method == "GET")
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
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
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

    let http = MockHTTPClient(
      dataHandler: { request in
        switch await counter.next() {
        case 1:
          #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1")
          #expect(request.method == "GET")

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
          let data = try WuhuJSON.encoder.encode(baseline)
          return (data, HTTPResponse(statusCode: 200, headers: [:]))

        case 2:
          #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/enqueue?lane=followUp")
          #expect(request.method == "POST")

          let body = try #require(request.body)
          let decoded = try WuhuJSON.decoder.decode(QueuedUserMessage.self, from: body)
          #expect(decoded.author == .unknown)
          #expect(decoded.content == .text("hello"))

          let data = try WuhuJSON.encoder.encode(QueueItemID(rawValue: "q1"))
          return (data, HTTPResponse(statusCode: 200, headers: [:]))

        default:
          throw URLError(.badURL)
        }
      },
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/follow?sinceCursor=1&stopAfterIdle=1")
        #expect(request.headers["Accept"] == "text/event-stream")

        return AsyncThrowingStream { continuation in
          continuation.yield(.init(data: #"{"type":"assistant_text_delta","delta":"Hi"}"#))
          continuation.yield(.init(data: #"{"type":"done"}"#))
          continuation.finish()
        }
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
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
    let http = MockHTTPClient(
      dataHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/model")
        #expect(request.method == "POST")

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
        let data = try WuhuJSON.encoder.encode(response)
        return (data, HTTPResponse(statusCode: 200, headers: [:]))
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
    let response = try await client.setSessionModel(sessionID: "s1", provider: .openai, model: "gpt-5.2-codex", reasoningEffort: .high)
    #expect(response.applied == true)
    #expect(response.session.model == "gpt-5.2-codex")
  }

  @Test func followSessionStreamSetsAcceptHeaderAndDecodesEvents() async throws {
    let http = MockHTTPClient(
      sseHandler: { request in
        #expect(request.url.absoluteString == "http://127.0.0.1:5530/v1/sessions/s1/follow")
        #expect(request.headers["Accept"] == "text/event-stream")

        return AsyncThrowingStream { continuation in
          continuation.yield(.init(data: #"{"type":"idle"}"#))
          continuation.yield(.init(data: #"{"type":"done"}"#))
          continuation.finish()
        }
      },
    )

    let client = try WuhuClient(baseURL: #require(URL(string: "http://127.0.0.1:5530")), http: http)
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

private struct MockHTTPClient: HTTPClient {
  var dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))?
  var sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)?

  init(
    dataHandler: (@Sendable (HTTPRequest) async throws -> (Data, HTTPResponse))? = nil,
    sseHandler: (@Sendable (HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error>)? = nil,
  ) {
    self.dataHandler = dataHandler
    self.sseHandler = sseHandler
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    guard let dataHandler else {
      throw PiAIError.unsupported("MockHTTPClient.dataHandler not set")
    }
    return try await dataHandler(request)
  }

  func sse(for request: HTTPRequest) async throws -> AsyncThrowingStream<SSEMessage, any Error> {
    guard let sseHandler else {
      throw PiAIError.unsupported("MockHTTPClient.sseHandler not set")
    }
    return try await sseHandler(request)
  }
}
