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

      let req = StartBashRequest(tag: "t1", command: "echo hello", cwd: "/tmp")
      try await MuxRunnerCodec.writeRequest(stream, op: .startBash, payload: req)
      try await stream.finish()

      var iter = serverSession.inbound.makeAsyncIterator()
      let inbound = await iter.next()!
      let reader = MuxStreamReader(stream: inbound)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      #expect(op == .startBash)
      let decoded = try MuxRunnerCodec.decode(StartBashRequest.self, from: payload)
      #expect(decoded.command == "echo hello")
      #expect(decoded.cwd == "/tmp")
      #expect(decoded.tag == "t1")
    }
  }

  @Test("Full RPC round-trip with InMemoryRunner", arguments: TransportKind.allCases)
  func fullRPCRoundTrip(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunner()
      await runner.seedDirectory(path: "/workspace")
      await runner.seedFile(path: "/workspace/hello.txt", content: "hello from runner")
      await runner.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test output\n", timedOut: false, terminated: false))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let coordinator = BashTagCoordinator()
      let client = MuxRunnerClient(name: "test-runner", session: clientSession)
      await client.setCallbacks(coordinator)
      let callbackTask = Task { await client.startCallbackListener() }
      defer { callbackTask.cancel() }

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

      // Test bash via fire-and-forget pattern (startBash + callback)
      let capture = BashResultCapture()
      await coordinator.setResultHandler { _, result in
        await capture.set(result: result)
      }
      _ = try await client.startBash(tag: "rpc-bash-1", command: "echo test", cwd: "/workspace", timeout: nil)
      // Wait for callback
      try await Task.sleep(for: .seconds(1))
      let receivedResult = await capture.get()
      #expect(receivedResult?.exitCode == 0)
      #expect(receivedResult?.output == "test output\n")

      // Test createDirectory
      try await client.createDirectory(path: "/workspace/subdir/nested", withIntermediateDirectories: true)
      let subdirExists = try await client.exists(path: "/workspace/subdir/nested")
      #expect(subdirExists == .directory)
    }
  }

  @Test("Multiple concurrent RPCs", arguments: TransportKind.allCases)
  func concurrentRPCs(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunner()
      await runner.seedDirectory(path: "/tmp")

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

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
      let runner = InMemoryRunner()

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
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
      let runner = InMemoryRunner()

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
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
      let runner = InMemoryRunner()

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      do {
        _ = try await client.readString(path: "/nonexistent", encoding: .utf8)
        Issue.record("Should have thrown")
      } catch {
        let msg = String(describing: error)
        #expect(msg.contains("not found") || msg.contains("File not found") || msg.contains("request failed"))
      }
    }
  }

  @Test("StartBash returns immediately, result comes via callback", arguments: TransportKind.allCases)
  func startBashReturnsImmediately(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunner()
      await runner.stubBash(pattern: "echo fast", result: BashResult(exitCode: 0, output: "fast\n", timedOut: false, terminated: false))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let coordinator = BashTagCoordinator()
      let client = MuxRunnerClient(name: "test-runner", session: clientSession)
      await client.setCallbacks(coordinator)
      let callbackTask = Task { await client.startCallbackListener() }
      defer { callbackTask.cancel() }

      // startBash should return immediately
      let started = try await client.startBash(tag: "fast-1", command: "echo fast", cwd: "/tmp", timeout: nil)
      #expect(started.alreadyRunning == false)
      #expect(started.tag == "fast-1")
    }
  }

  @Test("Idempotent startBash: same tag returns alreadyRunning", arguments: TransportKind.allCases)
  func idempotentStartBash(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = InMemoryRunner()
      await runner.stubBash(pattern: "echo", result: BashResult(exitCode: 0, output: "ok\n", timedOut: false, terminated: false))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // First start
      let first = try await client.startBash(tag: "dup-1", command: "echo 1", cwd: "/tmp", timeout: nil)
      #expect(first.alreadyRunning == false)

      // Second start with same tag — should be idempotent
      let second = try await client.startBash(tag: "dup-1", command: "echo 2", cwd: "/tmp", timeout: nil)
      #expect(second.alreadyRunning == true)
    }
  }

  @Test("CancelBash cancels a running process", arguments: TransportKind.allCases)
  func cancelBashCancels(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowInMemoryRunner()
      await runner.seedDirectory(path: "/tmp")

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // Start a slow bash
      let started = try await client.startBash(tag: "slow-1", command: "slow", cwd: "/tmp", timeout: nil)
      #expect(started.alreadyRunning == false)

      // Cancel it
      let cancelResult = try await client.cancelBash(tag: "slow-1")
      #expect(cancelResult == .cancelled)

      // Cancel again — should be notFound
      let cancelResult2 = try await client.cancelBash(tag: "slow-1")
      #expect(cancelResult2 == .notFound)
    }
  }

  @Test("Slow bash doesn't block fast concurrent operations", arguments: TransportKind.allCases)
  func slowDoesNotBlockFast(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowInMemoryRunner()
      await runner.seedDirectory(path: "/tmp")

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // Fire slow bash in background (startBash returns immediately anyway)
      _ = try await client.startBash(tag: "slow-2", command: "slow", cwd: "/tmp", timeout: nil)

      // Fast exists calls should complete immediately
      let start = ContinuousClock.now
      for _ in 0 ..< 5 {
        let existence = try await client.exists(path: "/tmp")
        #expect(existence == .directory)
      }
      let elapsed = ContinuousClock.now - start

      // 5 exists calls should complete in well under 1 second
      #expect(elapsed < .milliseconds(500), "Fast ops should not be blocked by slow bash")

      // Clean up
      _ = try await client.cancelBash(tag: "slow-2")
    }
  }
}

// MARK: - SlowInMemoryRunner for timing tests

/// A variant of InMemoryRunner where bash calls take a configurable delay.
actor SlowInMemoryRunner: Runner {
  nonisolated let id: RunnerID = .local

  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]
  private var activeTasks: [String: Task<Void, Never>] = [:]
  private var callbacks: (any RunnerCallbacks)?

  func seedDirectory(path: String) {
    directories.insert(path)
  }

  func setCallbacks(_ cb: any RunnerCallbacks) async {
    callbacks = cb
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil {
      return BashStarted(tag: tag, alreadyRunning: true)
    }
    let cb = callbacks
    let task = Task {
      do {
        try await Task.sleep(for: .seconds(60))
        try? await cb?.bashFinished(tag: tag, result: BashResult(exitCode: 0, output: "slow done\n", timedOut: false, terminated: false))
      } catch {
        try? await cb?.bashFinished(tag: tag, result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))
      }
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> BashCancelResult {
    guard let task = activeTasks.removeValue(forKey: tag) else {
      return .notFound
    }
    task.cancel()
    return .cancelled
  }

  func readData(path: String) async throws -> Data {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    return data
  }

  func readString(path: String, encoding: String.Encoding) async throws -> String {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    guard let s = String(data: data, encoding: encoding) else {
      throw RunnerError.requestFailed(message: "Cannot decode")
    }
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

private actor BashResultCapture {
  var result: BashResult?

  func set(result: BashResult) {
    self.result = result
  }

  func get() -> BashResult? {
    result
  }
}
