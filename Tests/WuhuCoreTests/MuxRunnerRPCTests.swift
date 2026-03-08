import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
import MuxWebSocket
import Testing
import WSClient
@testable import WuhuCore

// MARK: - Transport abstraction for parameterized tests

enum TransportKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case inMemory
  case webSocket

  var testDescription: String {
    rawValue
  }
}

/// Provides a mux session pair over the specified transport.
enum MuxTransportFactory {
  /// Create a mux session pair and run the body with them.
  /// The sessions are closed when the body returns.
  static func withPair(
    transport: TransportKind,
    body: @Sendable @escaping (MuxSession, MuxSession) async throws -> Void,
  ) async throws {
    switch transport {
    case .inMemory:
      try await withInMemoryPair(body: body)
    case .webSocket:
      try await withWebSocketPair(body: body)
    }
  }

  private static func withInMemoryPair(
    body: @Sendable @escaping (MuxSession, MuxSession) async throws -> Void,
  ) async throws {
    let (connA, connB) = InMemoryConnection.makePair()
    let client = MuxSession(connection: connA, role: .initiator, config: MuxConfig(keepaliveInterval: nil))
    let server = MuxSession(connection: connB, role: .responder, config: MuxConfig(keepaliveInterval: nil))
    let taskA = Task { try await client.run() }
    let taskB = Task { try await server.run() }
    defer {
      taskA.cancel()
      taskB.cancel()
    }
    try await body(client, server)
    await client.close()
    await server.close()
  }

  private static func withWebSocketPair(
    body: @Sendable @escaping (MuxSession, MuxSession) async throws -> Void,
  ) async throws {
    let serverSessionHolder = _SessionHolder()

    let portStream = AsyncStream<Int>.makeStream()

    let router = Router()
    let app = Application(
      router: router,
      server: .http1WebSocketUpgrade { _, _, _ in
        .upgrade([:]) { inbound, outbound, _ in
          let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
          let session = MuxSession(connection: conn, role: .responder, config: MuxConfig(keepaliveInterval: nil))
          await serverSessionHolder.set(session)
          try await session.run()
        }
      },
      configuration: .init(address: .hostname("127.0.0.1", port: 0)),
      onServerRunning: { channel in
        portStream.continuation.yield(channel.localAddress!.port!)
        portStream.continuation.finish()
      },
      logger: Logger(label: "test-ws-server"),
    )

    let serverTask = Task { try await app.run() }
    defer { serverTask.cancel() }

    var portIter = portStream.stream.makeAsyncIterator()
    guard let port = await portIter.next() else {
      throw MuxTestError.serverSessionNotEstablished
    }

    try await WebSocketClient.connect(
      url: .init("ws://127.0.0.1:\(port)"),
      logger: Logger(label: "test-ws-client"),
    ) { inbound, outbound, _ in
      let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
      let clientSession = MuxSession(connection: conn, role: .initiator, config: MuxConfig(keepaliveInterval: nil))

      let runTask = Task { try await clientSession.run() }

      var serverSession: MuxSession?
      for _ in 0 ..< 100 {
        serverSession = await serverSessionHolder.get()
        if serverSession != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard let serverSession else {
        runTask.cancel()
        throw MuxTestError.serverSessionNotEstablished
      }

      try await body(clientSession, serverSession)

      await clientSession.close()
      try? await Task.sleep(for: .milliseconds(100))
      await serverSession.close()
      runTask.cancel()
    }
  }
}

private actor _SessionHolder {
  var session: MuxSession?
  func set(_ s: MuxSession) {
    session = s
  }

  func get() -> MuxSession? {
    session
  }
}

enum MuxTestError: Error {
  case serverSessionNotEstablished
}

// MARK: - Parameterized Test Suite

@Suite("Mux Runner RPC")
struct MuxRunnerRPCTests {
  @Test("Codec round-trip: request frame encode/decode", arguments: TransportKind.allCases)
  func codecRoundTrip(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let stream = try await clientSession.open()

      let req = BashRequest(command: "echo hello", cwd: "/tmp", timeout: nil)
      try await MuxRunnerCodec.writeRequest(stream, op: .bash, payload: req)
      try await stream.finish()

      var iter = serverSession.inbound.makeAsyncIterator()
      let inbound = await iter.next()!
      let reader = MuxStreamReader(stream: inbound)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      #expect(op == .bash)
      let decoded = try MuxRunnerCodec.decode(BashRequest.self, from: payload)
      #expect(decoded.command == "echo hello")
      #expect(decoded.cwd == "/tmp")
    }
  }

  @Test("Full RPC round-trip with InMemoryRunnerCommands", arguments: TransportKind.allCases)
  func fullRPCRoundTrip(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()
      await runner.seedDirectory(path: "/workspace")
      await runner.seedFile(path: "/workspace/hello.txt", content: "hello from runner")
      await runner.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test output\n", timedOut: false, terminated: false))

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)

      // Test exists
      let fileExists = try await client.exists(path: "/workspace/hello.txt")
      #expect(fileExists == .file)

      let dirExists = try await client.exists(path: "/workspace")
      #expect(dirExists == .directory)

      let notFound = try await client.exists(path: "/workspace/nope")
      #expect(notFound == .notFound)

      // Test readString
      let content = try await client.readString(path: "/workspace/hello.txt", encoding: .utf8)
      #expect(content == "hello from runner")

      // Test writeString + readString
      try await client.writeString(path: "/workspace/new.txt", content: "created", createIntermediateDirectories: false, encoding: .utf8)
      let newContent = try await client.readString(path: "/workspace/new.txt", encoding: .utf8)
      #expect(newContent == "created")

      // Test binary write + read
      let binaryData = Data([0xDE, 0xAD, 0xBE, 0xEF])
      try await client.writeData(path: "/workspace/data.bin", data: binaryData, createIntermediateDirectories: false)
      let readData = try await client.readData(path: "/workspace/data.bin")
      #expect(readData == binaryData)

      // Test listDirectory
      let entries = try await client.listDirectory(path: "/workspace")
      let names = entries.map(\.name).sorted()
      #expect(names.contains("hello.txt"))
      #expect(names.contains("new.txt"))

      // Test bash via startBash + waitForBashResult
      let tag = "test-bash-1"
      _ = try await client.startBash(tag: tag, command: "echo test", cwd: "/workspace", timeout: nil)
      let bashResult = try await client.waitForBashResult(tag: tag)
      #expect(bashResult.exitCode == 0)
      #expect(bashResult.output == "test output\n")

      // Test createDirectory
      try await client.createDirectory(path: "/workspace/subdir/nested", withIntermediateDirectories: true)
      let subdirExists = try await client.exists(path: "/workspace/subdir/nested")
      #expect(subdirExists == .directory)
    }
  }

  @Test("Multiple concurrent RPCs", arguments: TransportKind.allCases)
  func concurrentRPCs(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()
      await runner.seedDirectory(path: "/tmp")

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)

      try await withThrowingTaskGroup(of: FileExistence.self) { group in
        for _ in 0 ..< 10 {
          group.addTask {
            try await client.exists(path: "/tmp")
          }
        }
        var results: [FileExistence] = []
        for try await result in group {
          results.append(result)
        }
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0 == .directory })
      }
    }
  }

  @Test("Hello handshake: version match", arguments: TransportKind.allCases)
  func helloVersionMatch(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let helloStream = try await clientSession.open()
      let hello = HelloResponse(runnerName: "test-client", version: muxRunnerProtocolVersion)
      try await MuxRunnerCodec.writeRequest(helloStream, op: .hello, payload: hello)
      try await helloStream.finish()

      let reader = MuxStreamReader(stream: helloStream)
      let (ok, op, payload) = try await MuxRunnerCodec.readResponse(reader)

      #expect(ok == true)
      #expect(op == .hello)
      let response = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
      #expect(response.runnerName == "test-runner")
      #expect(response.version == muxRunnerProtocolVersion)
    }
  }

  @Test("Hello handshake: version mismatch rejected", arguments: TransportKind.allCases)
  func helloVersionMismatch(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let helloStream = try await clientSession.open()
      let hello = HelloResponse(runnerName: "test-client", version: 999)
      try await MuxRunnerCodec.writeRequest(helloStream, op: .hello, payload: hello)
      try await helloStream.finish()

      let reader = MuxStreamReader(stream: helloStream)
      let (ok, op, payload) = try await MuxRunnerCodec.readResponse(reader)

      #expect(ok == false)
      #expect(op == .hello)
      let errorMsg = String(decoding: Data(payload), as: UTF8.self)
      #expect(errorMsg.contains("Version mismatch"))
    }
  }

  @Test("Error propagation: runner error surfaces on client", arguments: TransportKind.allCases)
  func errorPropagation(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)

      do {
        _ = try await client.readString(path: "/nonexistent", encoding: .utf8)
        Issue.record("Should have thrown")
      } catch {
        let msg = String(describing: error)
        #expect(msg.contains("not found") || msg.contains("File not found") || msg.contains("request failed"))
      }
    }
  }

  @Test("Large payload round-trip (~25KB bash output)", arguments: TransportKind.allCases)
  func largePayloadRoundTrip(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunnerCommands()

      var lines: [String] = ["import Foundation", "import SwiftUI", ""]
      for i in 1 ... 687 {
        lines.append("  let property\(i): String = \"value\(i)\" // padding to simulate real code")
      }
      lines.append("")
      let largeOutput = lines.joined(separator: "\n")

      #expect(largeOutput.utf8.count > 16 * 1024, "Test output must exceed 16KB")

      await runner.stubBash(pattern: "cat bigfile", result: BashResult(exitCode: 0, output: largeOutput, timedOut: false, terminated: false))

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)
      let tag = "large-bash-1"
      _ = try await client.startBash(tag: tag, command: "cat bigfile", cwd: "/", timeout: nil)
      let result = try await client.waitForBashResult(tag: tag)

      #expect(result.exitCode == 0)
      #expect(result.output == largeOutput)
      #expect(result.output.count == largeOutput.count)
    }
  }

  @Test("Slow bash does not block fast concurrent operations", arguments: TransportKind.allCases)
  func slowDoesNotBlockFast(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowInMemoryRunnerCommands()
      await runner.seedDirectory(path: "/tmp")

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)

      // Fire slow bash in background
      let bashTag = "slow-bash-1"
      _ = try await client.startBash(tag: bashTag, command: "slow", cwd: "/tmp", timeout: nil)
      let waitTask = Task { try await client.waitForBashResult(tag: bashTag) }
      defer { waitTask.cancel() }

      try await Task.sleep(for: .milliseconds(50))

      // Fast exists calls should complete immediately
      let start = ContinuousClock.now
      for _ in 0 ..< 5 {
        let existence = try await client.exists(path: "/tmp")
        #expect(existence == .directory)
      }
      let elapsed = ContinuousClock.now - start

      #expect(elapsed < .milliseconds(500), "Fast ops should not be blocked by slow bash")

      // Cancel the slow bash
      _ = try? await client.cancelBash(tag: bashTag)
    }
  }
}

// MARK: - SlowInMemoryRunnerCommands

/// A RunnerCommands variant where bash delays 1 second.
actor SlowInMemoryRunnerCommands: RunnerCommands {
  nonisolated let id: RunnerID = .local

  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]
  private let bridge = BashCallbackBridge()
  private var activeTasks: [String: Task<Void, Never>] = [:]

  func seedDirectory(path: String) {
    directories.insert(path)
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil { return BashStarted(tag: tag, alreadyRunning: true) }
    let bridge = bridge
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(for: .seconds(1))
        _ = try? await bridge.bashFinished(tag: tag, result: BashResult(exitCode: 0, output: "slow done\n", timedOut: false, terminated: false))
      } catch is CancellationError {
        _ = try? await bridge.bashFinished(tag: tag, result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))
      } catch {}
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> CancelResult {
    guard let task = activeTasks.removeValue(forKey: tag) else { return CancelResult(cancelled: false) }
    task.cancel()
    return CancelResult(cancelled: true)
  }

  func waitForBashResult(tag: String) async throws -> BashResult {
    try await bridge.waitForResult(tag: tag)
  }

  func readData(path: String) async throws -> Data {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    return data
  }

  func readString(path: String, encoding: String.Encoding) async throws -> String {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    guard let s = String(data: data, encoding: encoding) else { throw RunnerError.requestFailed(message: "Cannot decode") }
    return s
  }

  func writeData(path: String, data: Data, createIntermediateDirectories _: Bool) async throws {
    files[path] = data
  }

  func writeString(path: String, content: String, createIntermediateDirectories _: Bool, encoding: String.Encoding) async throws {
    files[path] = content.data(using: encoding)
  }

  func exists(path: String) async throws -> FileExistence {
    if files[path] != nil { return .file }
    if directories.contains(path) { return .directory }
    return .notFound
  }

  func listDirectory(path _: String) async throws -> [DirectoryEntry] {
    []
  }

  func enumerateDirectory(root _: String) async throws -> [EnumeratedEntry] {
    []
  }

  func createDirectory(path: String, withIntermediateDirectories _: Bool) async throws {
    directories.insert(path)
  }

  func find(params _: FindParams) async throws -> FindResult {
    FindResult(entries: [], totalBeforeLimit: 0)
  }

  func grep(params _: GrepParams) async throws -> GrepResult {
    GrepResult(matches: [], matchCount: 0, limitReached: false, linesTruncated: false)
  }

  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    MaterializeResponse(workspacePath: params.destinationPath)
  }
}

private actor ErrorHolder {
  var error: (any Error)?
  func set(_ e: any Error) {
    error = e
  }

  func get() -> (any Error)? {
    error
  }
}
