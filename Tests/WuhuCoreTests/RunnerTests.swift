import Dependencies
import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

// MARK: - InMemoryRunner for testing

/// A test runner that operates on an in-memory filesystem.
/// Conforms to the Runner protocol, enabling tool-level and handler-level testing
/// without touching the real filesystem.
actor InMemoryRunner: Runner {
  nonisolated let id: RunnerID

  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]

  /// Bash commands and their scripted responses.
  private var bashResponses: [(pattern: String, result: BashResult)] = []

  init(id: RunnerID = .local) {
    self.id = id
  }

  // MARK: - Test helpers

  func seedFile(path: String, content: String) {
    files[path] = Data(content.utf8)
    // Ensure parent directories exist
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/" && !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  func seedFile(path: String, data: Data) {
    files[path] = data
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/" && !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  func seedDirectory(path: String) {
    directories.insert(path)
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/" && !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  func stubBash(pattern: String, result: BashResult) {
    bashResponses.append((pattern: pattern, result: result))
  }

  func fileContent(path: String) -> String? {
    files[path].map { String(decoding: $0, as: UTF8.self) }
  }

  // MARK: - Runner protocol

  func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult {
    for (pattern, result) in bashResponses {
      if command.contains(pattern) { return result }
    }
    // Default: return empty success
    return BashResult(exitCode: 0, output: "", timedOut: false, terminated: false)
  }

  func readData(path: String) async throws -> Data {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    return data
  }

  func readString(path: String, encoding: String.Encoding) async throws -> String {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    guard let s = String(data: data, encoding: encoding) else {
      throw RunnerError.requestFailed(message: "Cannot decode \(path) with encoding \(encoding)")
    }
    return s
  }

  func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    if createIntermediateDirectories {
      var dir = (path as NSString).deletingLastPathComponent
      while dir != "/" && !dir.isEmpty {
        directories.insert(dir)
        dir = (dir as NSString).deletingLastPathComponent
      }
    }
    files[path] = data
  }

  func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws {
    guard let data = content.data(using: encoding) else {
      throw RunnerError.requestFailed(message: "Cannot encode with \(encoding)")
    }
    try await writeData(path: path, data: data, createIntermediateDirectories: createIntermediateDirectories)
  }

  func exists(path: String) async throws -> FileExistence {
    if files[path] != nil { return .file }
    if directories.contains(path) { return .directory }
    return .notFound
  }

  func listDirectory(path: String) async throws -> [DirectoryEntry] {
    guard directories.contains(path) else { throw RunnerError.fileNotFound(path: path) }
    let prefix = path.hasSuffix("/") ? path : path + "/"
    var entries: Set<String> = []
    for key in files.keys {
      if key.hasPrefix(prefix) {
        let rest = String(key.dropFirst(prefix.count))
        let firstComponent = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        if !firstComponent.isEmpty { entries.insert(firstComponent) }
      }
    }
    for dir in directories {
      if dir.hasPrefix(prefix) && dir != path {
        let rest = String(dir.dropFirst(prefix.count))
        let firstComponent = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        if !firstComponent.isEmpty { entries.insert(firstComponent) }
      }
    }
    return entries.sorted().map { name in
      let full = prefix + name
      let isDir = directories.contains(full)
      return DirectoryEntry(name: name, isDirectory: isDir)
    }
  }

  func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    guard directories.contains(root) else { throw RunnerError.fileNotFound(path: root) }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var results: [EnumeratedEntry] = []
    for key in files.keys.sorted() {
      if key.hasPrefix(prefix) {
        let rel = String(key.dropFirst(prefix.count))
        results.append(EnumeratedEntry(relativePath: rel, absolutePath: key, isDirectory: false))
      }
    }
    for dir in directories.sorted() {
      if dir.hasPrefix(prefix) && dir != root {
        let rel = String(dir.dropFirst(prefix.count))
        results.append(EnumeratedEntry(relativePath: rel, absolutePath: dir, isDirectory: true))
      }
    }
    return results
  }

  func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    if withIntermediateDirectories {
      var dir = path
      while dir != "/" && !dir.isEmpty {
        directories.insert(dir)
        dir = (dir as NSString).deletingLastPathComponent
      }
    } else {
      directories.insert(path)
    }
  }
}

// MARK: - LocalRunner Tests

struct LocalRunnerTests {
  @Test func localRunnerHasLocalID() async {
    let runner = LocalRunner()
    #expect(runner.id == .local)
  }

  @Test func localRunnerReadWriteString() async throws {
    let io = InMemoryFileIO()
    let runner = LocalRunner()
    let path = "/tmp/test-runner-\(UUID().uuidString)/hello.txt"

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await runner.writeString(path: path, content: "Hello, runner!", createIntermediateDirectories: true, encoding: .utf8)
      let result = try await runner.readString(path: path, encoding: .utf8)
      #expect(result == "Hello, runner!")
    }
  }

  @Test func localRunnerExists() async throws {
    let io = InMemoryFileIO()
    io.seedFile(path: "/workspace/file.txt", content: "content")
    io.seedDirectory(path: "/workspace/subdir")
    let runner = LocalRunner()

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let fileResult = try await runner.exists(path: "/workspace/file.txt")
      #expect(fileResult == .file)

      let dirResult = try await runner.exists(path: "/workspace/subdir")
      #expect(dirResult == .directory)

      let missingResult = try await runner.exists(path: "/workspace/nope")
      #expect(missingResult == .notFound)
    }
  }

  @Test func localRunnerListDirectory() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: "/workspace")
    io.seedFile(path: "/workspace/a.txt", content: "a")
    io.seedFile(path: "/workspace/b.txt", content: "b")
    io.seedDirectory(path: "/workspace/subdir")
    let runner = LocalRunner()

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let entries = try await runner.listDirectory(path: "/workspace")
      let names = entries.map(\.name).sorted()
      #expect(names.contains("a.txt"))
      #expect(names.contains("b.txt"))
      #expect(names.contains("subdir"))
      let subdirEntry = entries.first { $0.name == "subdir" }
      #expect(subdirEntry?.isDirectory == true)
    }
  }

  @Test func localRunnerBashExecutesCommand() async throws {
    let runner = LocalRunner()
    let tmpDir = NSTemporaryDirectory() + "wuhu-runner-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let result = try await runner.runBash(command: "echo hello", cwd: tmpDir, timeout: 5)
    #expect(result.exitCode == 0)
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(!result.timedOut)
    // Clean up output file
    if let path = result.fullOutputPath { try? FileManager.default.removeItem(atPath: path) }
  }
}

// MARK: - RunnerServerHandler Tests

struct RunnerServerHandlerTests {
  @Test func handlerDispatchesBashToRunner() async throws {
    let mem = InMemoryRunner()
    await mem.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false))
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .bash(id: "r1", command: "echo test", cwd: "/", timeout: nil))
    guard case let .bash(id, result, error) = response else {
      Issue.record("Expected bash response")
      return
    }
    #expect(id == "r1")
    #expect(error == nil)
    #expect(result?.output == "test\n")
    #expect(result?.exitCode == 0)
  }

  @Test func handlerDispatchesReadFile() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/hello.txt", content: "world")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .readFile(id: "r2", path: "/workspace/hello.txt"))
    guard case let .readFile(id, base64Data, error) = response else {
      Issue.record("Expected readFile response")
      return
    }
    #expect(id == "r2")
    #expect(error == nil)
    let data = Data(base64Encoded: base64Data!)!
    #expect(String(decoding: data, as: UTF8.self) == "world")
  }

  @Test func handlerDispatchesReadString() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/test.txt", content: "hello runner")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .readString(id: "r3", path: "/workspace/test.txt"))
    guard case let .readString(id, content, error) = response else {
      Issue.record("Expected readString response")
      return
    }
    #expect(id == "r3")
    #expect(error == nil)
    #expect(content == "hello runner")
  }

  @Test func handlerDispatchesWriteAndRead() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let writeResponse = await handler.handle(request: .writeString(id: "w1", path: "/workspace/new.txt", content: "created", createDirs: false))
    guard case let .writeString(_, error) = writeResponse else {
      Issue.record("Expected writeString response")
      return
    }
    #expect(error == nil)

    let readResponse = await handler.handle(request: .readString(id: "r4", path: "/workspace/new.txt"))
    guard case let .readString(_, content, readError) = readResponse else {
      Issue.record("Expected readString response")
      return
    }
    #expect(readError == nil)
    #expect(content == "created")
  }

  @Test func handlerReturnsErrorForMissingFile() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .readFile(id: "r5", path: "/nonexistent"))
    guard case let .readFile(_, _, error) = response else {
      Issue.record("Expected readFile response")
      return
    }
    #expect(error != nil)
    #expect(error!.contains("not found") || error!.contains("File not found"))
  }

  @Test func handlerDispatchesExists() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/file.txt", content: "data")
    await mem.seedDirectory(path: "/workspace/dir")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let fileResp = await handler.handle(request: .exists(id: "e1", path: "/workspace/file.txt"))
    guard case let .exists(_, existence, _) = fileResp else {
      Issue.record("Expected exists response")
      return
    }
    #expect(existence == .file)

    let dirResp = await handler.handle(request: .exists(id: "e2", path: "/workspace/dir"))
    guard case let .exists(_, dirExistence, _) = dirResp else {
      Issue.record("Expected exists response")
      return
    }
    #expect(dirExistence == .directory)

    let missingResp = await handler.handle(request: .exists(id: "e3", path: "/workspace/nope"))
    guard case let .exists(_, missingExistence, _) = missingResp else {
      Issue.record("Expected exists response")
      return
    }
    #expect(missingExistence == .notFound)
  }

  @Test func handlerDispatchesListDirectory() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    await mem.seedFile(path: "/workspace/a.txt", content: "a")
    await mem.seedDirectory(path: "/workspace/sub")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .listDirectory(id: "l1", path: "/workspace"))
    guard case let .listDirectory(_, entries, error) = response else {
      Issue.record("Expected listDirectory response")
      return
    }
    #expect(error == nil)
    let names = entries!.map(\.name).sorted()
    #expect(names.contains("a.txt"))
    #expect(names.contains("sub"))
  }

  @Test func handlerDispatchesCreateDirectory() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let response = await handler.handle(request: .createDirectory(id: "c1", path: "/workspace/new/nested", withIntermediateDirectories: true))
    guard case let .createDirectory(_, error) = response else {
      Issue.record("Expected createDirectory response")
      return
    }
    #expect(error == nil)

    let existsResp = await handler.handle(request: .exists(id: "e4", path: "/workspace/new/nested"))
    guard case let .exists(_, existence, _) = existsResp else {
      Issue.record("Expected exists response")
      return
    }
    #expect(existence == .directory)
  }

  @Test func handlerHelloResponse() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "my-runner")

    let response = await handler.handle(request: .hello(serverName: "wuhu-server", version: runnerProtocolVersion))
    guard case let .hello(runnerName, version) = response else {
      Issue.record("Expected hello response")
      return
    }
    #expect(runnerName == "my-runner")
    #expect(version == runnerProtocolVersion)
  }
}

// MARK: - Wire Protocol Serialization Tests

struct RunnerWireProtocolTests {
  @Test func requestRoundTrip() throws {
    let requests: [RunnerRequest] = [
      .hello(serverName: "test-server", version: 3),
      .bash(id: "b1", command: "echo hi", cwd: "/tmp", timeout: 30.0),
      .bash(id: "b2", command: "ls", cwd: "/", timeout: nil),
      .readFile(id: "rf1", path: "/workspace/file.txt"),
      .writeFile(id: "wf1", path: "/workspace/out.txt", base64Data: "aGVsbG8=", createDirs: true),
      .writeString(id: "ws1", path: "/workspace/out.txt", content: "hello", createDirs: false),
      .exists(id: "e1", path: "/workspace/test"),
      .listDirectory(id: "ld1", path: "/workspace"),
      .enumerateDirectory(id: "ed1", root: "/workspace"),
      .createDirectory(id: "cd1", path: "/workspace/new", withIntermediateDirectories: true),
      .readString(id: "rs1", path: "/workspace/file.txt"),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for request in requests {
      let data = try encoder.encode(request)
      let decoded = try decoder.decode(RunnerRequest.self, from: data)
      #expect(decoded == request)
    }
  }

  @Test func responseRoundTrip() throws {
    let responses: [RunnerResponse] = [
      .hello(runnerName: "test-runner", version: 3),
      .bash(id: "b1", result: BashResult(exitCode: 0, output: "hello\n", timedOut: false, terminated: false, fullOutputPath: "/tmp/out.log"), error: nil),
      .bash(id: "b2", result: nil, error: "command not found"),
      .readFile(id: "rf1", base64Data: "aGVsbG8=", error: nil),
      .readFile(id: "rf2", base64Data: nil, error: "File not found"),
      .writeFile(id: "wf1", error: nil),
      .writeString(id: "ws1", error: nil),
      .exists(id: "e1", existence: .file, error: nil),
      .exists(id: "e2", existence: .directory, error: nil),
      .exists(id: "e3", existence: .notFound, error: nil),
      .listDirectory(id: "ld1", entries: [DirectoryEntry(name: "a.txt", isDirectory: false), DirectoryEntry(name: "sub", isDirectory: true)], error: nil),
      .enumerateDirectory(id: "ed1", entries: [EnumeratedEntry(relativePath: "a.txt", absolutePath: "/workspace/a.txt", isDirectory: false)], error: nil),
      .createDirectory(id: "cd1", error: nil),
      .readString(id: "rs1", content: "hello world", error: nil),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for response in responses {
      let data = try encoder.encode(response)
      let decoded = try decoder.decode(RunnerResponse.self, from: data)
      // We can't use == because RunnerResponse doesn't conform to Equatable
      // (BashResult? makes it tricky). Verify by re-encoding.
      let reEncoded = try encoder.encode(decoded)
      #expect(data == reEncoded)
    }
  }

  @Test func runnerIDWireEncoding() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    // Test .local
    let localData = try encoder.encode(RunnerID.local)
    let localDecoded = try decoder.decode(RunnerID.self, from: localData)
    #expect(localDecoded == .local)
    #expect(String(decoding: localData, as: UTF8.self) == "\"local\"")

    // Test .remote
    let remoteData = try encoder.encode(RunnerID.remote(name: "build-mac"))
    let remoteDecoded = try decoder.decode(RunnerID.self, from: remoteData)
    #expect(remoteDecoded == .remote(name: "build-mac"))
    #expect(String(decoding: remoteData, as: UTF8.self) == "\"remote:build-mac\"")
  }
}

// MARK: - RunnerConnection Tests

struct RunnerConnectionTests {
  @Test func connectionCorrelatesResponses() async throws {
    let connection = RunnerConnection(runnerName: "test") { _ in }

    // Simulate sending a request and getting a response
    let task = Task {
      try await connection.request(
        RunnerRequest.exists(id: "req1", path: "/test"),
        requestID: "req1",
      )
    }

    // Give the task time to register the continuation
    try await Task.sleep(nanoseconds: 50_000_000)

    // Simulate response arriving
    await connection.handleResponse(.exists(id: "req1", existence: .file, error: nil))

    let response = try await task.value
    guard case let .exists(_, existence, _) = response else {
      Issue.record("Expected exists response")
      return
    }
    #expect(existence == .file)
  }

  @Test func connectionCloseFailsPending() async throws {
    let connection = RunnerConnection(runnerName: "test") { _ in }

    let task = Task {
      try await connection.request(
        RunnerRequest.exists(id: "req2", path: "/test"),
        requestID: "req2",
      )
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    await connection.close()

    do {
      _ = try await task.value
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("disconnected"))
    }
  }

  @Test func connectionRejectsAfterClose() async throws {
    let connection = RunnerConnection(runnerName: "test") { _ in }
    await connection.close()

    do {
      _ = try await connection.request(
        RunnerRequest.exists(id: "req3", path: "/test"),
        requestID: "req3",
      )
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("disconnected"))
    }
  }
}

// MARK: - RunnerRegistry Tests

struct RunnerRegistryTests {
  @Test func registryAlwaysHasLocal() async throws {
    let registry = RunnerRegistry()
    let local = await registry.get(.local)
    #expect(local != nil)
    #expect(local?.id == .local)
  }

  @Test func registryRegisterAndGet() async throws {
    let registry = RunnerRegistry()
    let mem = InMemoryRunner(id: .remote(name: "build-linux"))
    await registry.register(mem)

    let fetched = await registry.get(.remote(name: "build-linux"))
    #expect(fetched != nil)
    #expect(fetched?.id == .remote(name: "build-linux"))
  }

  @Test func registryRemoveRemote() async throws {
    let registry = RunnerRegistry()
    let mem = InMemoryRunner(id: .remote(name: "temp"))
    await registry.register(mem)
    #expect(await registry.isAvailable(.remote(name: "temp")))

    await registry.remove(.remote(name: "temp"))
    let stillAvailable = await registry.isAvailable(.remote(name: "temp"))
    #expect(!stillAvailable)
  }

  @Test func registryCannotRemoveLocal() async throws {
    let registry = RunnerRegistry()
    await registry.remove(.local)
    #expect(await registry.isAvailable(.local))
  }

  @Test func registryListNames() async throws {
    let registry = RunnerRegistry()
    let mem1 = InMemoryRunner(id: .remote(name: "alpha"))
    let mem2 = InMemoryRunner(id: .remote(name: "beta"))
    await registry.register(mem1)
    await registry.register(mem2)

    let names = await registry.listRunnerNames()
    #expect(names.contains("local"))
    #expect(names.contains("alpha"))
    #expect(names.contains("beta"))
  }
}

// MARK: - In-process integration: RunnerServerHandler + RunnerConnection + RemoteRunnerClient

struct RunnerIntegrationTests {
  /// Tests the full in-process loop: RemoteRunnerClient → RunnerConnection → RunnerServerHandler → InMemoryRunner
  @Test func inProcessRemoteRunnerRoundTrip() async throws {
    // Set up the "runner side"
    let memRunner = InMemoryRunner(id: .local)
    await memRunner.seedFile(path: "/workspace/hello.txt", content: "Hello from runner!")
    await memRunner.seedDirectory(path: "/workspace")
    await memRunner.stubBash(pattern: "echo works", result: BashResult(exitCode: 0, output: "works\n", timedOut: false, terminated: false))

    let handler = RunnerServerHandler(runner: memRunner, name: "test-remote")

    // Two-step init: create connection, then set send closure that captures it
    let connection = RunnerConnection(runnerName: "test-remote")
    await connection.setSendMessage { messageText in
      let request = try JSONDecoder().decode(RunnerRequest.self, from: Data(messageText.utf8))
      let response = await handler.handle(request: request)
      let responseData = try JSONEncoder().encode(response)
      let decoded = try JSONDecoder().decode(RunnerResponse.self, from: responseData)
      await connection.handleResponse(decoded)
    }

    let remote = RemoteRunnerClient(name: "test-remote", connection: connection)

    // Test readString
    let content = try await remote.readString(path: "/workspace/hello.txt", encoding: .utf8)
    #expect(content == "Hello from runner!")

    // Test exists
    let fileExists = try await remote.exists(path: "/workspace/hello.txt")
    #expect(fileExists == .file)
    let dirExists = try await remote.exists(path: "/workspace")
    #expect(dirExists == .directory)
    let notFound = try await remote.exists(path: "/workspace/nope")
    #expect(notFound == .notFound)

    // Test writeString + readString
    try await remote.writeString(path: "/workspace/new.txt", content: "created remotely", createIntermediateDirectories: false, encoding: .utf8)
    let newContent = try await remote.readString(path: "/workspace/new.txt", encoding: .utf8)
    #expect(newContent == "created remotely")

    // Test listDirectory
    let entries = try await remote.listDirectory(path: "/workspace")
    let names = entries.map(\.name).sorted()
    #expect(names.contains("hello.txt"))
    #expect(names.contains("new.txt"))

    // Test bash
    let bashResult = try await remote.runBash(command: "echo works", cwd: "/workspace", timeout: nil)
    #expect(bashResult.exitCode == 0)
    #expect(bashResult.output == "works\n")

    // Test createDirectory
    try await remote.createDirectory(path: "/workspace/subdir/nested", withIntermediateDirectories: true)
    let subdirExists = try await remote.exists(path: "/workspace/subdir/nested")
    #expect(subdirExists == .directory)
  }

  @Test func remoteRunnerReportsErrorsFromRunner() async throws {
    let memRunner = InMemoryRunner(id: .local)
    let handler = RunnerServerHandler(runner: memRunner, name: "test-err")

    let connection = RunnerConnection(runnerName: "test-err")
    await connection.setSendMessage { messageText in
      let request = try JSONDecoder().decode(RunnerRequest.self, from: Data(messageText.utf8))
      let response = await handler.handle(request: request)
      let responseData = try JSONEncoder().encode(response)
      let decoded = try JSONDecoder().decode(RunnerResponse.self, from: responseData)
      await connection.handleResponse(decoded)
    }

    let remote = RemoteRunnerClient(name: "test-err", connection: connection)

    // Reading a nonexistent file should throw
    do {
      _ = try await remote.readString(path: "/nonexistent", encoding: .utf8)
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("not found") || String(describing: error).contains("File not found") || String(describing: error).contains("request failed"))
    }
  }

  @Test func remoteRunnerDisconnectThrows() async throws {
    let connection = RunnerConnection(runnerName: "dead-runner") { _ in }
    await connection.close()
    let remote = RemoteRunnerClient(name: "dead-runner", connection: connection)

    do {
      _ = try await remote.exists(path: "/test")
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("disconnected"))
    }
  }
}
