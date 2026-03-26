import Fetch
import Foundation
import Serve
import ServeTesting
import Testing
import WuhuCore
@testable import WuhuRunner

struct HTTPRunnerHandlerTests {
  @Test func readResolvesRelativePathAgainstBasePath() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerHandlerTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceFile = root.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(
      at: sourceFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "one\ntwo\nthree\n".write(to: sourceFile, atomically: true, encoding: .utf8)

    let response: HTTPRunnerV1.ReadResponse = try await invokeJSON(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/read",
      payload: HTTPRunnerV1.ReadRequest(
        path: "Sources/App.swift",
        basePath: root.path,
        offset: 2,
        limit: 1
      ),
      as: HTTPRunnerV1.ReadResponse.self
    )

    #expect(response.resolvedPath == sourceFile.path)
    #expect(response.content == "two")
    #expect(response.totalLines == 4)
    #expect(response.startLine == 2)
    #expect(response.endLine == 2)
    #expect(response.hasMore)
    #expect(response.nextOffset == 3)
  }

  @Test func lsSortsEntriesAndAppliesLimit() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerHandlerTests")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root.appendingPathComponent("zebra"), withIntermediateDirectories: true)
    try "alpha".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "omega".write(to: root.appendingPathComponent("Z.txt"), atomically: true, encoding: .utf8)

    let response: HTTPRunnerV1.LsResponse = try await invokeJSON(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/ls",
      payload: HTTPRunnerV1.LsRequest(
        path: ".",
        basePath: root.path,
        limit: 2
      ),
      as: HTTPRunnerV1.LsResponse.self
    )

    #expect(response.resolvedPath == root.path)
    #expect(response.totalEntries == 3)
    #expect(response.returnedEntries == 2)
    #expect(response.hasMore)
    #expect(response.entries.map(\.name) == ["a.txt", "Z.txt"])
  }

  @Test func editPreservesBomAndLineEndings() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerHandlerTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("notes.txt")
    let original = "\u{FEFF}first\r\nold\r\nlast\r\n"
    try Data(original.utf8).write(to: fileURL)

    let response: HTTPRunnerV1.EditResponse = try await invokeJSON(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/edit",
      payload: HTTPRunnerV1.EditRequest(
        path: "notes.txt",
        basePath: root.path,
        oldText: "old\n",
        newText: "new\n"
      ),
      as: HTTPRunnerV1.EditResponse.self
    )

    let updated = try Data(contentsOf: fileURL)
    #expect(String(decoding: updated, as: UTF8.self) == "\u{FEFF}first\r\nnew\r\nlast\r\n")
    #expect(response.resolvedPath == fileURL.path)
    #expect(response.firstChangedLine == 2)
    #expect(response.diff.contains("@@ line 2 @@"))
    #expect(response.diff.contains("-old"))
    #expect(response.diff.contains("+new"))
  }

  @Test func relativePathWithoutBasePathReturnsStructuredError() async throws {
    let response = try await invokeResponse(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/read",
      payload: HTTPRunnerV1.ReadRequest(path: "notes.txt"),
      method: .post
    )

    let error = try await response.body.json(HTTPRunnerV1.ErrorResponse.self, decoder: WuhuJSON.decoder)
    #expect(response.status == Status.badRequest)
    #expect(error.error.code == HTTPRunnerV1.ErrorCode.missingBasePath)
  }
}

struct HTTPRunnerRawHTTPTests {
  @Test func writeConsumesContentLengthBodyOverRawHTTP() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerRawHTTPTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = HTTPRunnerV1.WriteRequest(
      path: "hello.txt",
      basePath: root.path,
      content: "hello world",
      createDirectories: true
    )
    let wire = try await roundTripRawHTTP(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/write",
      payload: payload
    )

    let response = try decodeHTTPJSONResponse(wire, as: HTTPRunnerV1.WriteResponse.self)
    let content = try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8)

    #expect(wire.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.bytesWritten == payload.content.utf8.count)
    #expect(content == "hello world")
  }

  @Test func editConsumesChunkedBodyOverRawHTTP() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerRawHTTPTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("edit.txt")
    try "before\nold\nafter\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let payload = HTTPRunnerV1.EditRequest(
      path: "edit.txt",
      basePath: root.path,
      oldText: "old\n",
      newText: "new\n"
    )
    let bodyData = try WuhuJSON.encoder.encode(payload)
    let chunks = [
      Array(bodyData.prefix(bodyData.count / 2)),
      Array(bodyData.dropFirst(bodyData.count / 2)),
    ]

    let wire = try await roundTripChunkedRawHTTP(
      handler: WuhuHTTPRunnerServer.handler(runner: .wrapping(LocalRunner())),
      path: "/v1/fs/edit",
      bodyChunks: chunks
    )

    let response = try decodeHTTPJSONResponse(wire, as: HTTPRunnerV1.EditResponse.self)
    let content = try String(contentsOf: fileURL, encoding: .utf8)

    #expect(wire.contains("HTTP/1.1 200 OK\r\n"))
    #expect(response.firstChangedLine == 2)
    #expect(content == "before\nnew\nafter\n")
  }
}

@Suite(.serialized)
struct HTTPRunnerIntegrationTests {
  @Test func clientRoundTripsOverTCP() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerIntegrationTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let listener = try await WuhuHTTPRunnerServer.listen(
      host: "127.0.0.1",
      port: 0,
      runner: .wrapping(LocalRunner()),
      name: "test-runner"
    )

    do {
      let port = try #require(listener.localAddress?.port)
      let client = HTTPRunnerClient(
        baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
        name: "test-runner",
        basePath: root.path
      )
      let runner = client.runnerHandle()

      try await runner.writeText("notes.txt", "one\ntwo\nthree\n", true)

      let read = try await client.read(path: "notes.txt", offset: 2, limit: 1)
      let edit = try await client.edit(path: "notes.txt", oldText: "two\n", newText: "TWO\n")
      let listing = try await runner.listDirectory(".")
      let finalContent = try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8)

      #expect(read.content == "two")
      #expect(edit.firstChangedLine == 2)
      #expect(listing.map(\.name) == ["notes.txt"])
      #expect(finalContent == "one\nTWO\nthree\n")
    } catch {
      await listener.close()
      throw error
    }

    await listener.close()
  }

  @Test func runnerLocatorBuildsHTTPBackedHandle() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerIntegrationTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let listener = try await WuhuHTTPRunnerServer.listen(
      host: "127.0.0.1",
      port: 0,
      runner: .wrapping(LocalRunner()),
      name: "test-runner"
    )

    do {
      let port = try #require(listener.localAddress?.port)
      let locator = RunnerLocator.http(
        baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
        name: "test-runner",
        basePath: root.path
      )
      let runner = try await locator.resolve(.remote(name: "test-runner"))

      try await runner.writeText("hello.txt", "hello", true)
      let text = try await runner.readText("hello.txt")

      #expect(text == "hello")
    } catch {
      await listener.close()
      throw error
    }

    await listener.close()
  }

  @Test func bashStreamsTerminalResultOverTCP() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerIntegrationTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let listener = try await WuhuHTTPRunnerServer.listen(
      host: "127.0.0.1",
      port: 0,
      runner: .wrapping(LocalRunner()),
      name: "test-runner"
    )

    do {
      let port = try #require(listener.localAddress?.port)
      let client = HTTPRunnerClient(
        baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
        name: "test-runner"
      )

      try await client.startBash(
        taskID: "bash-1",
        command: "printf 'hello\\n'",
        cwd: root.path,
        timeout: nil
      )

      let stream = try await client.streamBash(taskID: "bash-1", after: nil)
      var events: [BashStreamEvent] = []
      for try await event in stream {
        events.append(event)
        try await client.ackBash(taskID: "bash-1", through: event.cursor)
      }

      #expect(events.count == 1)
      guard let event = events.first else {
        Issue.record("Expected one bash stream event")
        return
      }
      #expect(event.cursor == 1)

      guard case let .finished(result) = event.payload else {
        Issue.record("Expected terminal bash event")
        return
      }
      #expect(result.exitCode == 0)
      #expect(result.output == "hello\n")
    } catch {
      await listener.close()
      throw error
    }

    await listener.close()
  }

  @Test func runnerHandleRunBashUsesHTTPStreamingContract() async throws {
    let root = try makeTempDirectory(prefix: "HTTPRunnerIntegrationTests")
    defer { try? FileManager.default.removeItem(at: root) }

    let listener = try await WuhuHTTPRunnerServer.listen(
      host: "127.0.0.1",
      port: 0,
      runner: .wrapping(LocalRunner()),
      name: "test-runner"
    )

    do {
      let port = try #require(listener.localAddress?.port)
      let runner = RunnerHandle.http(
        baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
        name: "test-runner"
      )

      let result = try await runner.runBash(root.path, "printf 'runner\\n'", nil)
      #expect(result.exitCode == 0)
      #expect(result.output == "runner\n")
    } catch {
      await listener.close()
      throw error
    }

    await listener.close()
  }
}

private func invokeResponse(
  handler: @escaping Handler,
  path: String,
  payload: some Encodable,
  method: Fetch.Method = .post
) async throws -> Response {
  let request = Request(
    url: try #require(URL(string: "http://runner.test\(path)")),
    method: method,
    body: try Body.json(payload, encoder: WuhuJSON.encoder)
  )
  return try await handler(request)
}

private func invokeJSON<ResponseBody: Decodable>(
  handler: @escaping Handler,
  path: String,
  payload: some Encodable,
  as _: ResponseBody.Type
) async throws -> ResponseBody {
  let response = try await invokeResponse(handler: handler, path: path, payload: payload)
  #expect((200 ..< 300).contains(response.status.code))
  return try await response.body.json(ResponseBody.self, decoder: WuhuJSON.decoder)
}

private func roundTripRawHTTP(
  handler: @escaping Handler,
  path: String,
  payload: some Encodable
) async throws -> String {
  let body = try WuhuJSON.encoder.encode(payload)
  let requestHead = "POST \(path) HTTP/1.1\r\n"
    + "Host: runner.test\r\n"
    + "Content-Type: application/json\r\n"
    + "Content-Length: \(body.count)\r\n"
    + "\r\n"
  let requestBytes = Array(requestHead.utf8) + Array(body)

  let connection = InMemoryConnection(inbound: requestBytes)
  try await Serve.serve(connection: connection, handler: handler)
  return connection.outputString()
}

private func roundTripChunkedRawHTTP(
  handler: @escaping Handler,
  path: String,
  bodyChunks: [[UInt8]]
) async throws -> String {
  let requestHead = "POST \(path) HTTP/1.1\r\n"
    + "Host: runner.test\r\n"
    + "Content-Type: application/json\r\n"
    + "Transfer-Encoding: chunked\r\n"
    + "\r\n"
  var requestBytes = Array(requestHead.utf8)

  for chunk in bodyChunks {
    requestBytes += Array(String(chunk.count, radix: 16).utf8)
    requestBytes += Array("\r\n".utf8)
    requestBytes += chunk
    requestBytes += Array("\r\n".utf8)
  }
  requestBytes += Array("0\r\n\r\n".utf8)

  let connection = InMemoryConnection(inbound: requestBytes)
  try await Serve.serve(connection: connection, handler: handler)
  return connection.outputString()
}

private func decodeHTTPJSONResponse<ResponseBody: Decodable>(
  _ wire: String,
  as _: ResponseBody.Type
) throws -> ResponseBody {
  let marker = "\r\n\r\n"
  let body = try #require(wire.range(of: marker)).upperBound
  let data = Data(wire[body...].utf8)
  return try WuhuJSON.decoder.decode(ResponseBody.self, from: data)
}

private func makeTempDirectory(prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
