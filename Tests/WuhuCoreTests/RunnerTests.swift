import Dependencies
import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

actor TestBashCallbacks: RunnerCallbacks {
  private var results: [String: BashResult] = [:]
  private var waiters: [String: [CheckedContinuation<BashResult, Never>]] = [:]
  private(set) var heartbeatCountByTag: [String: Int] = [:]

  func bashHeartbeat(tag: String) async throws {
    heartbeatCountByTag[tag, default: 0] += 1
  }

  func bashFinished(tag: String, result: BashResult) async throws {
    if let continuations = waiters.removeValue(forKey: tag) {
      for continuation in continuations {
        continuation.resume(returning: result)
      }
    } else {
      results[tag] = result
    }
  }

  func waitForResult(tag: String) async -> BashResult {
    if let result = results.removeValue(forKey: tag) {
      return result
    }
    return await withCheckedContinuation { continuation in
      waiters[tag, default: []].append(continuation)
    }
  }
}

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
  private var callbacks: (any RunnerCallbacks)?
  private var activeBashTags: Set<String> = []

  init(id: RunnerID = .local) {
    self.id = id
  }

  // MARK: - Test helpers

  func seedFile(path: String, content: String) {
    files[path] = Data(content.utf8)
    // Ensure parent directories exist
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/", !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  func seedFile(path: String, data: Data) {
    files[path] = data
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/", !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  func seedDirectory(path: String) {
    directories.insert(path)
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/", !dir.isEmpty {
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

  func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    self.callbacks = callbacks
  }

  func startBash(tag: String, command: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeBashTags.contains(tag) {
      return BashStarted(tag: tag, alreadyRunning: true)
    }
    activeBashTags.insert(tag)

    let result: BashResult = {
      for (pattern, result) in bashResponses {
        if command.contains(pattern) { return result }
      }
      return BashResult(exitCode: 0, output: "", timedOut: false, terminated: false)
    }()

    let callbacks = callbacks
    Task { [weak self] in
      try? await callbacks?.bashHeartbeat(tag: tag)
      try? await callbacks?.bashFinished(tag: tag, result: result)
      await self?.finishBash(tag: tag)
    }

    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> BashCancelResult {
    guard activeBashTags.remove(tag) != nil else { return .notFound }
    return .cancelled
  }

  private func finishBash(tag: String) {
    activeBashTags.remove(tag)
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
      while dir != "/", !dir.isEmpty {
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
      if dir.hasPrefix(prefix), dir != path {
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
      if dir.hasPrefix(prefix), dir != root {
        let rel = String(dir.dropFirst(prefix.count))
        results.append(EnumeratedEntry(relativePath: rel, absolutePath: dir, isDirectory: true))
      }
    }
    return results
  }

  func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    if withIntermediateDirectories {
      var dir = path
      while dir != "/", !dir.isEmpty {
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

  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    // In-memory materialization: copy all files/dirs under templatePath to destinationPath.
    let srcPrefix = params.templatePath.hasSuffix("/") ? params.templatePath : params.templatePath + "/"
    let dstPrefix = params.destinationPath.hasSuffix("/") ? params.destinationPath : params.destinationPath + "/"

    guard directories.contains(params.templatePath) else {
      throw RunnerError.fileNotFound(path: params.templatePath)
    }

    // Copy destination directory
    directories.insert(params.destinationPath)

    // Copy files
    for (path, data) in files {
      if path.hasPrefix(srcPrefix) {
        let rel = String(path.dropFirst(srcPrefix.count))
        let newPath = dstPrefix + rel
        files[newPath] = data
        // Ensure parent dirs
        var dir = (newPath as NSString).deletingLastPathComponent
        while dir != "/", !dir.isEmpty {
          directories.insert(dir)
          dir = (dir as NSString).deletingLastPathComponent
        }
      }
    }

    // Copy subdirectories
    for dir in Array(directories) {
      if dir.hasPrefix(srcPrefix) {
        let rel = String(dir.dropFirst(srcPrefix.count))
        directories.insert(dstPrefix + rel)
      }
    }

    return MaterializeResponse(workspacePath: params.destinationPath)
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
  @Test func localRunnerHasLocalID() {
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

    let result = try await LocalBash.run(command: "echo hello", cwd: tmpDir, timeoutSeconds: 5)
    #expect(result.exitCode == 0)
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(!result.timedOut)
    // Clean up output file
    if let path = result.fullOutputPath { try? FileManager.default.removeItem(atPath: path) }
  }

  @Test func localRunnerMaterializeCopiesTemplate() async throws {
    let fm = FileManager.default
    let runner = LocalRunner()
    let base = NSTemporaryDirectory() + "wuhu-runner-materialize-\(UUID().uuidString)"
    let templateDir = base + "/template"
    let workspacesDir = base + "/workspaces"
    try fm.createDirectory(atPath: templateDir, withIntermediateDirectories: true)
    try "# README".write(toFile: templateDir + "/README.md", atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(atPath: base) }

    let result = try await runner.materialize(params: MaterializeRequest(
      templatePath: templateDir,
      destinationPath: workspacesDir + "/sess-1",
    ))
    #expect(result.workspacePath == workspacesDir + "/sess-1")
    #expect(fm.fileExists(atPath: result.workspacePath + "/README.md"))
    let content = try String(contentsOfFile: result.workspacePath + "/README.md", encoding: .utf8)
    #expect(content == "# README")
  }

  @Test func localRunnerMaterializeRunsStartupScript() async throws {
    let fm = FileManager.default
    let runner = LocalRunner()
    let base = NSTemporaryDirectory() + "wuhu-runner-materialize-script-\(UUID().uuidString)"
    let templateDir = base + "/template"
    let workspacesDir = base + "/workspaces"
    try fm.createDirectory(atPath: templateDir, withIntermediateDirectories: true)
    try "echo done > marker.txt".write(toFile: templateDir + "/setup.sh", atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(atPath: base) }

    let result = try await runner.materialize(params: MaterializeRequest(
      templatePath: templateDir,
      destinationPath: workspacesDir + "/sess-2",
      startupScript: "setup.sh",
    ))

    let markerPath = result.workspacePath + "/marker.txt"
    #expect(fm.fileExists(atPath: markerPath))
    let content = try String(contentsOfFile: markerPath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(content == "done")
  }

  @Test func localRunnerMaterializeFailsForMissingTemplate() async throws {
    let runner = LocalRunner()
    do {
      _ = try await runner.materialize(params: MaterializeRequest(
        templatePath: "/nonexistent-\(UUID().uuidString)",
        destinationPath: "/tmp/should-not-exist",
      ))
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("not found") || String(describing: error).contains("File not found"))
    }
  }
}

// MARK: - RunnerServerHandler Tests

struct RunnerServerHandlerTests {
  @Test func handlerDispatchesBash() async throws {
    let mem = InMemoryRunner()
    await mem.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false))
    let callbacks = TestBashCallbacks()
    await mem.setCallbacks(callbacks)
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .startBash(id: "r1", StartBashRequest(tag: "tag-1", command: "echo test", cwd: "/", timeout: nil)))
    guard case let .startBash(id, result) = response else {
      Issue.record("Expected startBash response"); return
    }
    #expect(id == "r1")
    let started = try result.get()
    #expect(started.tag == "tag-1")
    #expect(started.alreadyRunning == false)

    let finished = await callbacks.waitForResult(tag: "tag-1")
    #expect(finished.output == "test\n")
    #expect(finished.exitCode == 0)
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
    #expect(try String(decoding: #require(binaryData), as: UTF8.self) == "world")
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

  @Test func handlerReturnsErrorForMissingFile() async {
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

  @Test func handlerHelloResponse() async {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "my-runner")

    let (response, _) = await handler.handle(request: .hello(HelloRequest(serverName: "wuhu-server", version: muxRunnerProtocolVersion)))
    guard case let .hello(helloResp) = response else {
      Issue.record("Expected hello response"); return
    }
    #expect(helloResp.runnerName == "my-runner")
    #expect(helloResp.version == muxRunnerProtocolVersion)
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

  @Test func handlerDispatchesMaterialize() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/templates/myapp")
    await mem.seedFile(path: "/templates/myapp/README.md", content: "# My App")
    await mem.seedFile(path: "/templates/myapp/src/main.swift", content: "print(\"hello\")")
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, binaryData) = await handler.handle(request: .materialize(
      id: "m1",
      MaterializeRequest(templatePath: "/templates/myapp", destinationPath: "/workspaces/sess-1"),
    ))
    guard case let .materialize(id, result) = response else {
      Issue.record("Expected materialize response"); return
    }
    #expect(id == "m1")
    #expect(binaryData == nil)
    let r = try result.get()
    #expect(r.workspacePath == "/workspaces/sess-1")

    // Verify files were copied
    let readme = try await mem.readString(path: "/workspaces/sess-1/README.md", encoding: .utf8)
    #expect(readme == "# My App")
    let main = try await mem.readString(path: "/workspaces/sess-1/src/main.swift", encoding: .utf8)
    #expect(main == "print(\"hello\")")
  }

  @Test func handlerMaterializeReturnsErrorForMissingTemplate() async {
    let mem = InMemoryRunner()
    let handler = RunnerServerHandler(runner: mem, name: "test-runner")

    let (response, _) = await handler.handle(request: .materialize(
      id: "m2",
      MaterializeRequest(templatePath: "/nonexistent", destinationPath: "/workspaces/sess-2"),
    ))
    guard case let .materialize(_, result) = response else {
      Issue.record("Expected materialize response"); return
    }
    switch result {
    case .success: Issue.record("Expected error")
    case let .failure(err): #expect(err.message.contains("not found") || err.message.contains("File not found"))
    }
  }
}

// MARK: - RunnerID Wire Encoding Tests

struct RunnerIDWireEncodingTests {
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

// MARK: - RunnerRegistry Tests

struct RunnerRegistryTests {
  @Test func registryAlwaysHasLocal() async {
    let registry = RunnerRegistry()
    let local = await registry.get(.local)
    #expect(local != nil)
    #expect(local?.id == .local)
  }

  @Test func registryRegisterAndGet() async {
    let registry = RunnerRegistry()
    let mem = InMemoryRunner(id: .remote(name: "build-linux"))
    await registry.register(mem)

    let fetched = await registry.get(.remote(name: "build-linux"))
    #expect(fetched != nil)
    #expect(fetched?.id == .remote(name: "build-linux"))
  }

  @Test func registryRemoveRemote() async {
    let registry = RunnerRegistry()
    let mem = InMemoryRunner(id: .remote(name: "temp"))
    await registry.register(mem)
    #expect(await registry.isAvailable(.remote(name: "temp")))

    await registry.remove(.remote(name: "temp"))
    let stillAvailable = await registry.isAvailable(.remote(name: "temp"))
    #expect(!stillAvailable)
  }

  @Test func registryCannotRemoveLocal() async {
    let registry = RunnerRegistry()
    await registry.remove(.local)
    #expect(await registry.isAvailable(.local))
  }

  @Test func registryListNames() async {
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
