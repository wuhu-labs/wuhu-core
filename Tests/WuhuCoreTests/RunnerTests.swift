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

  func find(params: FindParams) async throws -> FindResult {
    // Simple in-memory find: match file paths against the glob pattern.
    let allFiles = files.keys.sorted()
    var matching: [String] = []
    for path in allFiles {
      // Compute relative path from root
      let root = params.root.hasSuffix("/") ? params.root : params.root + "/"
      guard path.hasPrefix(root) else { continue }
      let rel = String(path.dropFirst(root.count))
      if ToolGlob.matches(pattern: params.pattern, path: rel, anchored: true) {
        matching.append(rel)
      }
    }
    let limited = Array(matching.prefix(params.limit))
    return FindResult(entries: limited.map { FindEntry(relativePath: $0) }, totalBeforeLimit: matching.count)
  }

  func grep(params: GrepParams) async throws -> GrepResult {
    // Simple in-memory grep: search through in-memory files.
    let root = params.root.hasSuffix("/") ? params.root : params.root + "/"
    let allFiles = files.keys.filter { $0.hasPrefix(root) }.sorted()
    var matches: [GrepMatch] = []
    var matchCount = 0

    for path in allFiles {
      if matchCount >= params.limit { break }
      guard let data = files[path], let content = String(data: data, encoding: .utf8) else { continue }
      let rel = String(path.dropFirst(root.count))

      if let glob = params.glob {
        guard ToolGlob.matches(pattern: glob, path: rel, anchored: true) else { continue }
      }

      let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      for (idx, line) in lines.enumerated() {
        if matchCount >= params.limit { break }
        let found: Bool = if params.literal {
          params.ignoreCase ? line.lowercased().contains(params.pattern.lowercased()) : line.contains(params.pattern)
        } else {
          (try? NSRegularExpression(pattern: params.pattern, options: params.ignoreCase ? [.caseInsensitive] : []))
            .flatMap { $0.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) } != nil
        }
        if found {
          matchCount += 1
          matches.append(GrepMatch(file: rel, lineNumber: idx + 1, line: line))
        }
      }
    }

    return GrepResult(matches: matches, matchCount: matchCount, limitReached: matchCount >= params.limit, linesTruncated: false)
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
  @Test func handlerDispatchesBash() async throws {
    let mem = InMemoryRunner()
    await mem.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false))
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .bash(id: "r1", BashRequest(command: "echo test", cwd: "/", timeout: nil)))
    guard case let .bash(id, result) = response else {
      Issue.record("Expected bash response"); return
    }
    #expect(id == "r1")
    let r = try result.get()
    #expect(r.output == "test\n")
    #expect(r.exitCode == 0)
  }

  @Test func handlerDispatchesReadBinary() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/hello.txt", content: "world")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, binaryData) = await handler.handle(request: .read(id: "r2", ReadRequest(path: "/workspace/hello.txt", binary: true)))
    guard case let .read(id, result) = response else {
      Issue.record("Expected read response"); return
    }
    #expect(id == "r2")
    let r = try result.get()
    #expect(r.content == nil) // binary mode — content in companion frame
    #expect(r.size == 5)
    #expect(binaryData != nil)
    #expect(String(decoding: binaryData!, as: UTF8.self) == "world")
  }

  @Test func handlerDispatchesReadText() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/test.txt", content: "hello runner")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, binaryData) = await handler.handle(request: .read(id: "r3", ReadRequest(path: "/workspace/test.txt", binary: false)))
    guard case let .read(id, result) = response else {
      Issue.record("Expected read response"); return
    }
    #expect(id == "r3")
    let r = try result.get()
    #expect(r.content == "hello runner")
    #expect(binaryData == nil)
  }

  @Test func handlerDispatchesWriteAndRead() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (writeResp, _) = await handler.handle(request: .write(id: "w1", WriteRequest(path: "/workspace/new.txt", createDirs: false, content: "created")))
    guard case let .write(_, writeResult) = writeResp else {
      Issue.record("Expected write response"); return
    }
    _ = try writeResult.get()

    let (readResp, _) = await handler.handle(request: .read(id: "r4", ReadRequest(path: "/workspace/new.txt")))
    guard case let .read(_, readResult) = readResp else {
      Issue.record("Expected read response"); return
    }
    let r = try readResult.get()
    #expect(r.content == "created")
  }

  @Test func handlerReturnsErrorForMissingFile() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .read(id: "r5", ReadRequest(path: "/nonexistent")))
    guard case let .read(_, result) = response else {
      Issue.record("Expected read response"); return
    }
    switch result {
    case .success: Issue.record("Expected error")
    case let .failure(msg): #expect(msg.message.contains("not found") || msg.message.contains("File not found"))
    }
  }

  @Test func handlerDispatchesExists() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/file.txt", content: "data")
    await mem.seedDirectory(path: "/workspace/dir")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (fileResp, _) = await handler.handle(request: .exists(id: "e1", ExistsRequest(path: "/workspace/file.txt")))
    guard case let .exists(_, result) = fileResp else { Issue.record("Expected exists response"); return }
    #expect(try result.get().existence == .file)

    let (dirResp, _) = await handler.handle(request: .exists(id: "e2", ExistsRequest(path: "/workspace/dir")))
    guard case let .exists(_, dirResult) = dirResp else { Issue.record("Expected exists response"); return }
    #expect(try dirResult.get().existence == .directory)

    let (missingResp, _) = await handler.handle(request: .exists(id: "e3", ExistsRequest(path: "/workspace/nope")))
    guard case let .exists(_, missingResult) = missingResp else { Issue.record("Expected exists response"); return }
    #expect(try missingResult.get().existence == .notFound)
  }

  @Test func handlerDispatchesListDirectory() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    await mem.seedFile(path: "/workspace/a.txt", content: "a")
    await mem.seedDirectory(path: "/workspace/sub")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .ls(id: "l1", LsRequest(path: "/workspace")))
    guard case let .ls(_, result) = response else { Issue.record("Expected ls response"); return }
    let entries = try result.get().entries
    let names = entries.map(\.name).sorted()
    #expect(names.contains("a.txt"))
    #expect(names.contains("sub"))
  }

  @Test func handlerDispatchesCreateDirectory() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .mkdir(id: "c1", MkdirRequest(path: "/workspace/new/nested", recursive: true)))
    guard case let .mkdir(_, result) = response else { Issue.record("Expected mkdir response"); return }
    _ = try result.get()

    let (existsResp, _) = await handler.handle(request: .exists(id: "e4", ExistsRequest(path: "/workspace/new/nested")))
    guard case let .exists(_, existsResult) = existsResp else { Issue.record("Expected exists response"); return }
    #expect(try existsResult.get().existence == .directory)
  }

  @Test func handlerHelloResponse() async throws {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "my-runner")

    let (response, _) = await handler.handle(request: .hello(HelloRequest(serverName: "wuhu-server", version: runnerProtocolVersion)))
    guard case let .hello(helloResp) = response else {
      Issue.record("Expected hello response"); return
    }
    #expect(helloResp.runnerName == "my-runner")
    #expect(helloResp.version == runnerProtocolVersion)
  }

  @Test func handlerDispatchesFind() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/src/main.swift", content: "import Foundation")
    await mem.seedFile(path: "/workspace/src/util.swift", content: "// util")
    await mem.seedFile(path: "/workspace/README.md", content: "# Readme")

    let handler = RunnerServerHandler(runner: mem, name: "finder")
    let (response, _) = await handler.handle(request: .find(id: "f1", FindParams(root: "/workspace", pattern: "**/*.swift", limit: 100)))
    guard case let .find(id, result) = response else { Issue.record("Expected find response"); return }
    #expect(id == "f1")
    let r = try result.get()
    #expect(r.entries.count == 2)
    #expect(r.entries.contains(where: { $0.relativePath == "src/main.swift" }))
    #expect(r.entries.contains(where: { $0.relativePath == "src/util.swift" }))
  }

  @Test func handlerDispatchesGrep() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/a.swift", content: "let x = 1\nlet TODO = 2\nlet z = 3")
    await mem.seedFile(path: "/workspace/b.swift", content: "// nothing here")

    let handler = RunnerServerHandler(runner: mem, name: "grepper")
    let (response, _) = await handler.handle(request: .grep(id: "g1", GrepParams(root: "/workspace", pattern: "TODO", literal: true, limit: 100)))
    guard case let .grep(id, result) = response else { Issue.record("Expected grep response"); return }
    #expect(id == "g1")
    let r = try result.get()
    #expect(r.matchCount == 1)
    #expect(r.matches.first?.file == "a.swift")
    #expect(r.matches.first?.lineNumber == 2)
  }

  @Test func handlerBinaryWrite() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
    let response = await handler.handleBinaryWrite(id: "bw1", path: "/workspace/image.png", data: data, createDirs: true)
    guard case let .write(id, result) = response else { Issue.record("Expected write response"); return }
    #expect(id == "bw1")
    let r = try result.get()
    #expect(r.bytesWritten == 4)

    // Verify data was written
    let readBack = try await mem.readData(path: "/workspace/image.png")
    #expect(readBack == data)
  }
}

// MARK: - Wire Protocol Serialization Tests

struct RunnerWireProtocolTests {
  @Test func requestRoundTrip() throws {
    let requests: [RunnerRequest] = [
      .hello(HelloRequest(serverName: "test-server", version: 5)),
      .bash(id: "b1", BashRequest(command: "echo hi", cwd: "/tmp", timeout: 30.0)),
      .bash(id: "b2", BashRequest(command: "ls", cwd: "/")),
      .read(id: "r1", ReadRequest(path: "/workspace/file.txt")),
      .read(id: "r2", ReadRequest(path: "/workspace/file.bin", binary: true)),
      .write(id: "w1", WriteRequest(path: "/workspace/out.txt", createDirs: true, content: "hello")),
      .write(id: "w2", WriteRequest(path: "/workspace/out.bin", createDirs: false)),
      .exists(id: "e1", ExistsRequest(path: "/workspace/test")),
      .ls(id: "l1", LsRequest(path: "/workspace")),
      .enumerate(id: "en1", EnumerateRequest(root: "/workspace")),
      .mkdir(id: "m1", MkdirRequest(path: "/workspace/new", recursive: true)),
      .find(id: "f1", FindParams(root: "/workspace", pattern: "*.swift", limit: 100)),
      .grep(id: "g1", GrepParams(root: "/workspace", pattern: "TODO", glob: "*.swift", ignoreCase: true, literal: true, contextLines: 2, limit: 50)),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for request in requests {
      let data = try encoder.encode(request)
      let decoded = try decoder.decode(RunnerRequest.self, from: data)
      #expect(decoded == request)
    }
  }

  @Test func requestEnvelopeFormat() throws {
    // Verify the envelope structure has v, id, op, p keys
    let request = RunnerRequest.bash(id: "test-123", BashRequest(command: "ls", cwd: "/tmp"))
    let data = try JSONEncoder().encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["v"] as? Int == 5)
    #expect(json["id"] as? String == "test-123")
    #expect(json["op"] as? String == "bash")
    #expect(json["p"] != nil)
  }

  @Test func responseRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()

    // Test success responses
    let successResponses: [(RunnerResponse, String)] = [
      (.hello(HelloResponse(runnerName: "test-runner", version: 5)), "hello"),
      (.bash(id: "b1", .success(BashResult(exitCode: 0, output: "hello\n", timedOut: false, terminated: false, fullOutputPath: "/tmp/out.log"))), "bash"),
      (.read(id: "r1", .success(ReadResponse(content: "hello world", size: 11))), "read"),
      (.read(id: "r2", .success(ReadResponse(size: 1024))), "read-binary"),
      (.write(id: "w1", .success(WriteResponse(bytesWritten: 5))), "write"),
      (.exists(id: "e1", .success(ExistsResponse(existence: .file))), "exists-file"),
      (.exists(id: "e2", .success(ExistsResponse(existence: .directory))), "exists-dir"),
      (.exists(id: "e3", .success(ExistsResponse(existence: .notFound))), "exists-missing"),
      (.ls(id: "l1", .success(LsResponse(entries: [DirectoryEntry(name: "a.txt", isDirectory: false), DirectoryEntry(name: "sub", isDirectory: true)]))), "ls"),
      (.enumerate(id: "en1", .success(EnumerateResponse(entries: [EnumeratedEntry(relativePath: "a.txt", absolutePath: "/workspace/a.txt", isDirectory: false)]))), "enumerate"),
      (.mkdir(id: "m1", .success(MkdirResponse())), "mkdir"),
      (.find(id: "f1", .success(FindResult(entries: [FindEntry(relativePath: "main.swift")], totalBeforeLimit: 1))), "find"),
      (.grep(id: "g1", .success(GrepResult(matches: [GrepMatch(file: "main.swift", lineNumber: 5, line: "// TODO: fix", isContext: false)], matchCount: 1, limitReached: false, linesTruncated: false))), "grep"),
    ]

    for (response, label) in successResponses {
      let data = try encoder.encode(response)
      let decoded = try decoder.decode(RunnerResponse.self, from: data)
      let reEncoded = try encoder.encode(decoded)
      #expect(data == reEncoded, "Round-trip failed for \(label)")
    }

    // Test error responses
    let errorResponses: [(RunnerResponse, String)] = [
      (.bash(id: "b2", .failure(RunnerWireError("command not found"))), "bash-err"),
      (.read(id: "r3", .failure(RunnerWireError("File not found"))), "read-err"),
      (.write(id: "w2", .failure(RunnerWireError("Permission denied"))), "write-err"),
      (.find(id: "f2", .failure(RunnerWireError("Path not found"))), "find-err"),
      (.grep(id: "g2", .failure(RunnerWireError("Path not found"))), "grep-err"),
    ]

    for (response, label) in errorResponses {
      let data = try encoder.encode(response)
      let decoded = try decoder.decode(RunnerResponse.self, from: data)
      let reEncoded = try encoder.encode(decoded)
      #expect(data == reEncoded, "Round-trip failed for \(label)")
    }
  }

  @Test func responseEnvelopeFormat() throws {
    // Success: has "ok" key
    let success = RunnerResponse.bash(id: "x", .success(BashResult(exitCode: 0, output: "", timedOut: false, terminated: false)))
    let sData = try JSONEncoder().encode(success)
    let sJson = try JSONSerialization.jsonObject(with: sData) as! [String: Any]
    #expect(sJson["v"] as? Int == 5)
    #expect(sJson["id"] as? String == "x")
    #expect(sJson["op"] as? String == "bash")
    #expect(sJson["ok"] != nil)
    #expect(sJson["err"] == nil)

    // Error: has "err" key
    let error = RunnerResponse.bash(id: "y", .failure(RunnerWireError("oops")))
    let eData = try JSONEncoder().encode(error)
    let eJson = try JSONSerialization.jsonObject(with: eData) as! [String: Any]
    #expect(eJson["err"] as? String == "oops")
    #expect(eJson["ok"] == nil)
  }

  @Test func binaryFrameRoundTrip() throws {
    let id = "550e8400-e29b-41d4-a716-446655440000"
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
    let frame = RunnerBinaryFrame.encode(id: id, data: payload)

    // 2 bytes length prefix + 36 bytes UUID string + 8 bytes payload
    #expect(frame.count == 2 + id.utf8.count + 8)

    guard let (decodedID, decodedPayload) = RunnerBinaryFrame.decode(frame) else {
      Issue.record("Failed to decode binary frame")
      return
    }
    #expect(decodedID == id)
    #expect(decodedPayload == payload)
  }

  @Test func binaryFrameShortID() throws {
    let id = "req-1"
    let payload = Data([0xCA, 0xFE])
    let frame = RunnerBinaryFrame.encode(id: id, data: payload)
    #expect(frame.count == 2 + id.utf8.count + 2)

    guard let (decodedID, decodedPayload) = RunnerBinaryFrame.decode(frame) else {
      Issue.record("Failed to decode binary frame")
      return
    }
    #expect(decodedID == id)
    #expect(decodedPayload == payload)
  }

  @Test func binaryFrameEmptyPayload() throws {
    let id = "test-empty"
    let frame = RunnerBinaryFrame.encode(id: id, data: Data())
    #expect(frame.count == 2 + id.utf8.count)

    guard let (decodedID, decodedPayload) = RunnerBinaryFrame.decode(frame) else {
      Issue.record("Failed to decode binary frame")
      return
    }
    #expect(decodedID == id)
    #expect(decodedPayload.isEmpty)
  }

  @Test func binaryFrameTooShort() throws {
    // Only 1 byte — can't even read the length prefix
    let result = RunnerBinaryFrame.decode(Data([0x01]))
    #expect(result == nil)

    // Length says 10 bytes but only 5 bytes of ID data
    let result2 = RunnerBinaryFrame.decode(Data([0x00, 0x0A, 0x41, 0x42, 0x43, 0x44, 0x45]))
    #expect(result2 == nil)
  }

  @Test func runnerIDWireEncoding() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let localData = try encoder.encode(RunnerID.local)
    let localDecoded = try decoder.decode(RunnerID.self, from: localData)
    #expect(localDecoded == .local)
    #expect(String(decoding: localData, as: UTF8.self) == "\"local\"")

    let remoteData = try encoder.encode(RunnerID.remote(name: "build-mac"))
    let remoteDecoded = try decoder.decode(RunnerID.self, from: remoteData)
    #expect(remoteDecoded == .remote(name: "build-mac"))
    #expect(String(decoding: remoteData, as: UTF8.self) == "\"remote:build-mac\"")
  }
}

// MARK: - RunnerConnection Tests

struct RunnerConnectionTests {
  @Test func connectionCorrelatesResponses() async throws {
    let connection = RunnerConnection(runnerName: "test")
    await connection.setSend(text: { _ in }, binary: { _ in })

    let task = Task {
      try await connection.request(
        RunnerRequest.exists(id: "req1", ExistsRequest(path: "/test")),
        requestID: "req1",
      )
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    await connection.handleResponse(.exists(id: "req1", .success(ExistsResponse(existence: .file))))

    let (response, _) = try await task.value
    guard case let .exists(_, result) = response else {
      Issue.record("Expected exists response"); return
    }
    #expect(try result.get().existence == .file)
  }

  @Test func connectionCorrelatesBinaryResponse() async throws {
    let connection = RunnerConnection(runnerName: "test")
    await connection.setSend(text: { _ in }, binary: { _ in })

    let task = Task {
      try await connection.request(
        RunnerRequest.read(id: "req-bin", ReadRequest(path: "/test.bin", binary: true)),
        requestID: "req-bin",
      )
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    // Send binary frame first, then text response
    let binaryPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let frame = RunnerBinaryFrame.encode(id: "req-bin", data: binaryPayload)
    await connection.handleBinaryFrame(frame)

    // Then text response (no content — binary mode)
    await connection.handleResponse(.read(id: "req-bin", .success(ReadResponse(size: 4))))

    let (response, data) = try await task.value
    guard case let .read(_, result) = response else {
      Issue.record("Expected read response"); return
    }
    let r = try result.get()
    #expect(r.size == 4)
    #expect(r.content == nil)
    #expect(data == binaryPayload)
  }

  @Test func connectionCorrelatesBinaryResponseTextFirst() async throws {
    let connection = RunnerConnection(runnerName: "test")
    await connection.setSend(text: { _ in }, binary: { _ in })

    let task = Task {
      try await connection.request(
        RunnerRequest.read(id: "req-bin2", ReadRequest(path: "/test.bin", binary: true)),
        requestID: "req-bin2",
      )
    }

    try await Task.sleep(nanoseconds: 50_000_000)

    // Text response first, then binary frame
    await connection.handleResponse(.read(id: "req-bin2", .success(ReadResponse(size: 3))))

    let binaryPayload = Data([0x01, 0x02, 0x03])
    let frame = RunnerBinaryFrame.encode(id: "req-bin2", data: binaryPayload)
    await connection.handleBinaryFrame(frame)

    let (_, data) = try await task.value
    #expect(data == binaryPayload)
  }

  @Test func connectionCloseFailsPending() async throws {
    let connection = RunnerConnection(runnerName: "test")
    await connection.setSend(text: { _ in }, binary: { _ in })

    let task = Task {
      try await connection.request(
        RunnerRequest.exists(id: "req2", ExistsRequest(path: "/test")),
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
    let connection = RunnerConnection(runnerName: "test")
    await connection.setSend(text: { _ in }, binary: { _ in })
    await connection.close()

    do {
      _ = try await connection.request(
        RunnerRequest.exists(id: "req3", ExistsRequest(path: "/test")),
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
  /// Create an in-process loopback: RemoteRunnerClient → RunnerConnection → RunnerServerHandler → Runner
  /// The connection's send closures dispatch to the handler and feed responses back.
  private static func makeLoopback(runner: InMemoryRunner, name: String) async -> (RemoteRunnerClient, RunnerConnection) {
    let handler = RunnerServerHandler(runner: runner, name: name)
    let connection = RunnerConnection(runnerName: name)
    await connection.setSend(
      text: { messageText in
        let request = try JSONDecoder().decode(RunnerRequest.self, from: Data(messageText.utf8))
        let (response, binaryData) = await handler.handle(request: request)
        let responseData = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(RunnerResponse.self, from: responseData)
        // If there's binary data, send it as a binary frame first
        if let binaryData, let id = decoded.responseID {
          let frame = RunnerBinaryFrame.encode(id: id, data: binaryData)
          await connection.handleBinaryFrame(frame)
        }
        await connection.handleResponse(decoded)
      },
      binary: { data in
        // Binary frame from client (e.g., binary write)
        guard let (id, payload) = RunnerBinaryFrame.decode(data) else { return }
        // We need to look up the pending write info — for the loopback test, we handle this inline
        // In the real protocol, the runner server tracks pending binary writes
        // For now, this path isn't tested in the loopback (text writes cover it)
        _ = (id, payload)
      },
    )
    let client = RemoteRunnerClient(name: name, connection: connection)
    return (client, connection)
  }

  @Test func inProcessRemoteRunnerRoundTrip() async throws {
    let memRunner = InMemoryRunner(id: .local)
    await memRunner.seedFile(path: "/workspace/hello.txt", content: "Hello from runner!")
    await memRunner.seedDirectory(path: "/workspace")
    await memRunner.stubBash(pattern: "echo works", result: BashResult(exitCode: 0, output: "works\n", timedOut: false, terminated: false))

    let (remote, _) = await Self.makeLoopback(runner: memRunner, name: "test-remote")

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

  @Test func inProcessBinaryReadRoundTrip() async throws {
    let memRunner = InMemoryRunner(id: .local)
    let binaryContent = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    await memRunner.seedFile(path: "/workspace/image.png", data: binaryContent)

    let (remote, _) = await Self.makeLoopback(runner: memRunner, name: "test-binary")

    let data = try await remote.readData(path: "/workspace/image.png")
    #expect(data == binaryContent)
  }

  @Test func remoteRunnerReportsErrorsFromRunner() async throws {
    let memRunner = InMemoryRunner(id: .local)
    let (remote, _) = await Self.makeLoopback(runner: memRunner, name: "test-err")

    do {
      _ = try await remote.readString(path: "/nonexistent", encoding: .utf8)
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("not found") || String(describing: error).contains("File not found") || String(describing: error).contains("request failed"))
    }
  }

  @Test func remoteRunnerDisconnectThrows() async throws {
    let connection = RunnerConnection(runnerName: "dead-runner")
    await connection.setSend(text: { _ in }, binary: { _ in })
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
