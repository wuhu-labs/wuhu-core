import Foundation

/// In-memory implementation of `RunnerCommands` for testing.
///
/// Simulates a runner without any real filesystem or process execution.
/// Bash responses can be scripted via `stubBash(pattern:result:)`.
/// Has an embedded `BashCallbackBridge` used by `waitForBashResult(tag:)`.
public actor InMemoryRunnerCommands: RunnerCommands {
  public nonisolated let id: RunnerID

  private var files: [String: Data] = [:]
  private var directories: Set<String> = ["/"]

  /// Scripted bash responses: first matching pattern wins.
  private var bashResponseStubs: [(pattern: String, result: BashResult)] = []

  /// Internal callbacks implementation (shared with embedded bridge).
  private let _callbackBridge = BashCallbackBridge()

  /// Additional callbacks to notify (e.g. for test assertions).
  private var extraCallbacks: (any RunnerCallbacks)?

  public init(id: RunnerID = .local) {
    self.id = id
  }

  // MARK: - Test helpers

  public func setExtraCallbacks(_ callbacks: any RunnerCallbacks) {
    extraCallbacks = callbacks
  }

  public func stubBash(pattern: String, result: BashResult) {
    bashResponseStubs.append((pattern: pattern, result: result))
  }

  public func seedFile(path: String, content: String) {
    files[path] = Data(content.utf8)
    ensureParentDirs(path)
  }

  public func seedFile(path: String, data: Data) {
    files[path] = data
    ensureParentDirs(path)
  }

  public func seedDirectory(path: String) {
    directories.insert(path)
    ensureParentDirs(path)
  }

  public func fileContent(path: String) -> String? {
    files[path].map { String(decoding: $0, as: UTF8.self) }
  }

  private func ensureParentDirs(_ path: String) {
    var dir = (path as NSString).deletingLastPathComponent
    while dir != "/", !dir.isEmpty {
      directories.insert(dir)
      dir = (dir as NSString).deletingLastPathComponent
    }
  }

  // MARK: - RunnerCommands: Bash

  private var activeBash: [String: Task<Void, Never>] = [:]

  public func startBash(
    tag: String,
    command: String,
    cwd _: String,
    timeout _: TimeInterval?,
  ) async throws -> BashStarted {
    if activeBash[tag] != nil {
      return BashStarted(tag: tag, alreadyRunning: true)
    }

    var result = BashResult(exitCode: 0, output: "", timedOut: false, terminated: false)
    for (pattern, r) in bashResponseStubs {
      if command.contains(pattern) { result = r; break }
    }

    let bridge = _callbackBridge
    let extra = extraCallbacks
    let task = Task { [result] in
      _ = try? await bridge.bashFinished(tag: tag, result: result)
      _ = try? await extra?.bashFinished(tag: tag, result: result)
      await self.bashTaskFinished(tag: tag)
    }
    activeBash[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  public func cancelBash(tag: String) async throws -> CancelResult {
    guard let task = activeBash.removeValue(forKey: tag) else {
      return CancelResult(cancelled: false)
    }
    task.cancel()
    _ = try? await _callbackBridge.bashFinished(
      tag: tag,
      result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true),
    )
    return CancelResult(cancelled: true)
  }

  private func bashTaskFinished(tag: String) {
    activeBash.removeValue(forKey: tag)
  }

  public func waitForBashResult(tag: String) async throws -> BashResult {
    try await _callbackBridge.waitForResult(tag: tag)
  }

  // MARK: - RunnerCommands: File I/O

  public func readData(path: String) async throws -> Data {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    return data
  }

  public func readString(path: String, encoding: String.Encoding) async throws -> String {
    guard let data = files[path] else { throw RunnerError.fileNotFound(path: path) }
    guard let s = String(data: data, encoding: encoding) else {
      throw RunnerError.requestFailed(message: "Cannot decode \(path)")
    }
    return s
  }

  public func writeData(
    path: String, data: Data, createIntermediateDirectories: Bool,
  ) async throws {
    if createIntermediateDirectories { ensureParentDirs(path) }
    files[path] = data
  }

  public func writeString(
    path: String, content: String, createIntermediateDirectories: Bool,
    encoding: String.Encoding,
  ) async throws {
    guard let data = content.data(using: encoding) else {
      throw RunnerError.requestFailed(message: "Cannot encode")
    }
    try await writeData(path: path, data: data, createIntermediateDirectories: createIntermediateDirectories)
  }

  public func exists(path: String) async throws -> FileExistence {
    if files[path] != nil { return .file }
    if directories.contains(path) { return .directory }
    return .notFound
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    guard directories.contains(path) else { throw RunnerError.fileNotFound(path: path) }
    let prefix = path.hasSuffix("/") ? path : path + "/"
    var entries: Set<String> = []
    for key in files.keys {
      if key.hasPrefix(prefix) {
        let rest = String(key.dropFirst(prefix.count))
        let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        if !first.isEmpty { entries.insert(first) }
      }
    }
    for dir in directories {
      if dir.hasPrefix(prefix), dir != path {
        let rest = String(dir.dropFirst(prefix.count))
        let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
        if !first.isEmpty { entries.insert(first) }
      }
    }
    return entries.sorted().map { name in
      let full = prefix + name
      return DirectoryEntry(name: name, isDirectory: directories.contains(full))
    }
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    guard directories.contains(root) else { throw RunnerError.fileNotFound(path: root) }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var results: [EnumeratedEntry] = []
    for key in files.keys.sorted() {
      if key.hasPrefix(prefix) {
        results.append(EnumeratedEntry(
          relativePath: String(key.dropFirst(prefix.count)),
          absolutePath: key,
          isDirectory: false,
        ))
      }
    }
    for dir in directories.sorted() {
      if dir.hasPrefix(prefix), dir != root {
        results.append(EnumeratedEntry(
          relativePath: String(dir.dropFirst(prefix.count)),
          absolutePath: dir,
          isDirectory: true,
        ))
      }
    }
    return results
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
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

  // MARK: - RunnerCommands: Search

  public func find(params: FindParams) async throws -> FindResult {
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
    return FindResult(
      entries: limited.map { FindEntry(relativePath: $0) },
      totalBeforeLimit: matching.count,
    )
  }

  public func grep(params: GrepParams) async throws -> GrepResult {
    let root = params.root.hasSuffix("/") ? params.root : params.root + "/"
    let allFiles = files.keys.filter { $0.hasPrefix(root) }.sorted()
    var matches: [GrepMatch] = []
    var matchCount = 0

    for path in allFiles {
      if matchCount >= params.limit { break }
      guard let data = files[path], let content = String(data: data, encoding: .utf8) else {
        continue
      }
      let rel = String(path.dropFirst(root.count))
      if let glob = params.glob {
        guard ToolGlob.matches(pattern: glob, path: rel, anchored: true) else { continue }
      }
      let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      for (idx, line) in lines.enumerated() {
        if matchCount >= params.limit { break }
        let found: Bool = params.literal
          ? (params.ignoreCase
            ? line.lowercased().contains(params.pattern.lowercased())
            : line.contains(params.pattern))
          : ((try? NSRegularExpression(
            pattern: params.pattern,
            options: params.ignoreCase ? [.caseInsensitive] : [],
          ))
          .flatMap {
            $0.firstMatch(
              in: line, range: NSRange(location: 0, length: (line as NSString).length))
          } != nil)
        if found {
          matchCount += 1
          matches.append(GrepMatch(file: rel, lineNumber: idx + 1, line: line))
        }
      }
    }
    return GrepResult(
      matches: matches, matchCount: matchCount, limitReached: matchCount >= params.limit,
      linesTruncated: false,
    )
  }

  // MARK: - RunnerCommands: Workspace

  public func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    let srcPrefix = params.templatePath.hasSuffix("/") ? params.templatePath : params.templatePath + "/"
    let dstPrefix =
      params.destinationPath.hasSuffix("/") ? params.destinationPath : params.destinationPath + "/"
    guard directories.contains(params.templatePath) else {
      throw RunnerError.fileNotFound(path: params.templatePath)
    }
    directories.insert(params.destinationPath)
    for (path, data) in files where path.hasPrefix(srcPrefix) {
      let rel = String(path.dropFirst(srcPrefix.count))
      files[dstPrefix + rel] = data
      ensureParentDirs(dstPrefix + rel)
    }
    for dir in Array(directories) where dir.hasPrefix(srcPrefix) {
      directories.insert(dstPrefix + String(dir.dropFirst(srcPrefix.count)))
    }
    return MaterializeResponse(workspacePath: params.destinationPath)
  }
}

/// Compatibility alias — tests written against the old name continue to compile.
public typealias InMemoryRunner = InMemoryRunnerCommands

// MARK: - InMemoryRunnerCallbacks

/// In-memory implementation of `RunnerCallbacks` for testing.
///
/// Collects bash output chunks and results so tests can assert on them.
/// Also bridges results to waiters via `waitForResult(tag:)`.
public actor InMemoryRunnerCallbacks: RunnerCallbacks {
  public struct CapturedOutput: Sendable, Equatable {
    public var tag: String
    public var chunk: String
  }

  private var outputs: [CapturedOutput] = []
  private var results: [String: BashResult] = [:]
  private var waiters: [String: CheckedContinuation<BashResult, any Error>] = [:]

  public init() {}

  public func bashOutput(tag: String, chunk: String) async throws -> Ack {
    outputs.append(CapturedOutput(tag: tag, chunk: chunk))
    return Ack()
  }

  public func bashFinished(tag: String, result: BashResult) async throws -> Ack {
    results[tag] = result
    waiters.removeValue(forKey: tag)?.resume(returning: result)
    return Ack()
  }

  // MARK: - Test helpers

  public func collectedOutputs() -> [CapturedOutput] { outputs }
  public func result(tag: String) -> BashResult? { results[tag] }

  /// Wait for a bash to finish. Returns immediately if the result is already available.
  public func waitForResult(tag: String) async throws -> BashResult {
    if let existing = results[tag] { return existing }
    return try await withCheckedThrowingContinuation { cont in
      waiters[tag] = cont
    }
  }
}
