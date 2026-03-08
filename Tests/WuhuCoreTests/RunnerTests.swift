import Dependencies
import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

// MARK: - InMemoryRunner for testing

/// A test runner that operates on an in-memory filesystem.
/// Conforms to the RunnerCommands protocol, enabling tool-level testing
/// without touching the real filesystem.
actor InMemoryRunner: RunnerCommands {
  nonisolated let id: RunnerID

  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]

  /// Bash commands and their scripted responses.
  private var bashResponses: [(pattern: String, result: BashResult)] = []

  /// Callbacks for pushing bash results.
  private var callbacks: (any RunnerCallbacks)?

  /// Active bash tasks by tag.
  private var activeTasks: [String: Task<Void, Never>] = [:]

  /// Tags that have already completed.
  private var completedTags: Set<String> = []

  init(id: RunnerID = .local) {
    self.id = id
  }

  // MARK: - Test helpers

  func setCallbacks(_ cb: any RunnerCallbacks) {
    callbacks = cb
  }

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

  // MARK: - RunnerCommands protocol

  func startBash(tag: String, command: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil || completedTags.contains(tag) {
      return BashStarted(tag: tag)
    }

    let callbacks = callbacks
    let bashResponses = bashResponses

    let task = Task<Void, Never> { [weak self] in
      var result = BashResult(exitCode: 0, output: "", timedOut: false, terminated: false)
      for (pattern, r) in bashResponses {
        if command.contains(pattern) { result = r; break }
      }

      if Task.isCancelled {
        result = BashResult(exitCode: 137, output: "", timedOut: false, terminated: true)
      }

      await self?.markCompleted(tag: tag)
      try? await callbacks?.bashFinished(tag: tag, result: result)
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag)
  }

  func cancelBash(tag: String) async throws -> CancelResult {
    if completedTags.contains(tag) {
      return .alreadyFinished
    }
    guard let task = activeTasks.removeValue(forKey: tag) else {
      return .notFound
    }
    task.cancel()
    return .cancelled
  }

  private func markCompleted(tag: String) {
    activeTasks.removeValue(forKey: tag)
    completedTags.insert(tag)
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
    let allFiles = files.keys.sorted()
    var matching: [String] = []
    for path in allFiles {
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
    let srcPrefix = params.templatePath.hasSuffix("/") ? params.templatePath : params.templatePath + "/"
    let dstPrefix = params.destinationPath.hasSuffix("/") ? params.destinationPath : params.destinationPath + "/"

    guard directories.contains(params.templatePath) else {
      throw RunnerError.fileNotFound(path: params.templatePath)
    }

    directories.insert(params.destinationPath)

    for (path, data) in files {
      if path.hasPrefix(srcPrefix) {
        let rel = String(path.dropFirst(srcPrefix.count))
        let newPath = dstPrefix + rel
        files[newPath] = data
        var dir = (newPath as NSString).deletingLastPathComponent
        while dir != "/", !dir.isEmpty {
          directories.insert(dir)
          dir = (dir as NSString).deletingLastPathComponent
        }
      }
    }

    for dir in Array(directories) {
      if dir.hasPrefix(srcPrefix) {
        let rel = String(dir.dropFirst(srcPrefix.count))
        directories.insert(dstPrefix + rel)
      }
    }

    return MaterializeResponse(workspacePath: params.destinationPath)
  }

  func grep(params: GrepParams) async throws -> GrepResult {
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
    let bridge = BashCallbackBridge()
    await runner.setCallbacks(bridge)

    let tmpDir = NSTemporaryDirectory() + "wuhu-runner-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let tag = UUID().uuidString
    _ = try await runner.startBash(tag: tag, command: "echo hello", cwd: tmpDir, timeout: 5)
    let result = try await bridge.waitForResult(tag: tag)
    #expect(result.exitCode == 0)
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(!result.timedOut)
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

// MARK: - InMemoryRunner Direct Tests

struct InMemoryRunnerDirectTests {
  @Test func readWriteString() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    try await mem.writeString(path: "/workspace/test.txt", content: "hello", createIntermediateDirectories: false, encoding: .utf8)
    let content = try await mem.readString(path: "/workspace/test.txt", encoding: .utf8)
    #expect(content == "hello")
  }

  @Test func existsChecks() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/file.txt", content: "data")
    await mem.seedDirectory(path: "/workspace/dir")

    #expect(try await mem.exists(path: "/workspace/file.txt") == .file)
    #expect(try await mem.exists(path: "/workspace/dir") == .directory)
    #expect(try await mem.exists(path: "/workspace/nope") == .notFound)
  }

  @Test func listDirectory() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/workspace")
    await mem.seedFile(path: "/workspace/a.txt", content: "a")
    await mem.seedDirectory(path: "/workspace/sub")

    let entries = try await mem.listDirectory(path: "/workspace")
    let names = entries.map(\.name).sorted()
    #expect(names.contains("a.txt"))
    #expect(names.contains("sub"))
  }

  @Test func createDirectory() async throws {
    let mem = InMemoryRunner()
    try await mem.createDirectory(path: "/workspace/new/nested", withIntermediateDirectories: true)
    #expect(try await mem.exists(path: "/workspace/new/nested") == .directory)
  }

  @Test func find() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/src/main.swift", content: "import Foundation")
    await mem.seedFile(path: "/workspace/src/util.swift", content: "// util")
    await mem.seedFile(path: "/workspace/README.md", content: "# Readme")

    let result = try await mem.find(params: FindParams(root: "/workspace", pattern: "**/*.swift", limit: 100))
    #expect(result.entries.count == 2)
    #expect(result.entries.contains(where: { $0.relativePath == "src/main.swift" }))
    #expect(result.entries.contains(where: { $0.relativePath == "src/util.swift" }))
  }

  @Test func grep() async throws {
    let mem = InMemoryRunner()
    await mem.seedFile(path: "/workspace/a.swift", content: "let x = 1\nlet TODO = 2\nlet z = 3")
    await mem.seedFile(path: "/workspace/b.swift", content: "// nothing here")

    let result = try await mem.grep(params: GrepParams(root: "/workspace", pattern: "TODO", literal: true, limit: 100))
    #expect(result.matchCount == 1)
    #expect(result.matches.first?.file == "a.swift")
    #expect(result.matches.first?.lineNumber == 2)
  }

  @Test func materialize() async throws {
    let mem = InMemoryRunner()
    await mem.seedDirectory(path: "/templates/myapp")
    await mem.seedFile(path: "/templates/myapp/README.md", content: "# My App")
    await mem.seedFile(path: "/templates/myapp/src/main.swift", content: "print(\"hello\")")

    let result = try await mem.materialize(params: MaterializeRequest(
      templatePath: "/templates/myapp",
      destinationPath: "/workspaces/sess-1",
    ))
    #expect(result.workspacePath == "/workspaces/sess-1")
    let readme = try await mem.readString(path: "/workspaces/sess-1/README.md", encoding: .utf8)
    #expect(readme == "# My App")
  }

  @Test func startBashWithCallbacks() async throws {
    let mem = InMemoryRunner()
    let bridge = BashCallbackBridge()
    await mem.setCallbacks(bridge)
    await mem.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false))

    let tag = "test-tag-1"
    let started = try await mem.startBash(tag: tag, command: "echo test", cwd: "/", timeout: nil)
    #expect(started.tag == tag)

    let result = try await bridge.waitForResult(tag: tag)
    #expect(result.exitCode == 0)
    #expect(result.output == "test\n")
  }

  @Test func readMissingFileThrows() async {
    let mem = InMemoryRunner()
    do {
      _ = try await mem.readData(path: "/nonexistent")
      Issue.record("Should have thrown")
    } catch {
      let msg = String(describing: error)
      #expect(msg.contains("not found") || msg.contains("File not found"))
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
  @Test func registryLocalNotPresentByDefault() async {
    let registry = RunnerRegistry()
    let local = await registry.get(.local)
    #expect(local == nil)
  }

  @Test func registryLocalAvailableWhenRegistered() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
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

  @Test func registryCanRemoveLocal() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
    #expect(await registry.isAvailable(.local))
    await registry.remove(.local)
    let stillAvailable = await registry.isAvailable(.local)
    #expect(!stillAvailable)
  }

  @Test func registryListNames() async {
    let registry = RunnerRegistry()
    let mem1 = InMemoryRunner(id: .remote(name: "alpha"))
    let mem2 = InMemoryRunner(id: .remote(name: "beta"))
    await registry.register(mem1)
    await registry.register(mem2)

    let names = await registry.listRunnerNames()
    #expect(!names.contains("local")) // local not registered
    #expect(names.contains("alpha"))
    #expect(names.contains("beta"))
  }

  @Test func registryListNamesWithLocal() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
    let mem1 = InMemoryRunner(id: .remote(name: "alpha"))
    await registry.register(mem1)

    let names = await registry.listRunnerNames()
    #expect(names.contains("local"))
    #expect(names.contains("alpha"))
  }
}
