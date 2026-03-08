import Dependencies
import Foundation

/// Local runner — executes everything on the local machine.
/// Uses the `FileIO` dependency for filesystem operations, preserving
/// testability via `InMemoryFileIO`.
public actor LocalRunner: Runner {
  public nonisolated let id: RunnerID = .local

  /// Callbacks target for pushing bash results.
  private var callbacks: (any RunnerCallbacks)?

  /// Active bash tasks keyed by tag, for cancellation.
  private var activeBashTasks: [String: Task<Void, Never>] = [:]

  public init() {}

  // MARK: - Callbacks

  /// Set the callbacks target. Must be called before startBash.
  public func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    self.callbacks = callbacks
  }

  // MARK: - Process execution (v3: fire-and-forget)

  public func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted {
    // Idempotent: if already running for this tag, return existing
    if activeBashTasks[tag] != nil {
      return BashStarted(tag: tag, alreadyRunning: true)
    }

    let callbacks = callbacks

    // Spawn the bash process in a background task
    let task = Task { [weak self] in
      let result: BashResult
      do {
        result = try await LocalBash.run(command: command, cwd: cwd, timeoutSeconds: timeout) { chunk in
          try? await callbacks?.bashOutput(tag: tag, chunk: chunk)
        }
      } catch is CancellationError {
        let terminated = BashResult(exitCode: -15, output: "", timedOut: false, terminated: true)
        try? await callbacks?.bashFinished(tag: tag, result: terminated)
        await self?.unregisterBashTask(tag: tag)
        return
      } catch {
        let errResult = BashResult(exitCode: -1, output: "Error: \(error)", timedOut: false, terminated: false)
        try? await callbacks?.bashFinished(tag: tag, result: errResult)
        await self?.unregisterBashTask(tag: tag)
        return
      }
      try? await callbacks?.bashFinished(tag: tag, result: result)
      await self?.unregisterBashTask(tag: tag)
    }

    activeBashTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  public func cancelBash(tag: String) async throws -> BashCancelResult {
    guard let task = activeBashTasks.removeValue(forKey: tag) else {
      return .notFound
    }
    task.cancel()
    return .cancelled
  }

  private func unregisterBashTask(tag: String) {
    activeBashTasks.removeValue(forKey: tag)
  }

  // MARK: - File I/O

  public func readData(path: String) async throws -> Data {
    @Dependency(\.fileIO) var fileIO
    return try fileIO.readData(path: path)
  }

  public func readString(path: String, encoding: String.Encoding) async throws -> String {
    @Dependency(\.fileIO) var fileIO
    return try fileIO.readString(path: path, encoding: encoding)
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    @Dependency(\.fileIO) var fileIO
    if createIntermediateDirectories {
      let dir = (path as NSString).deletingLastPathComponent
      try fileIO.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try fileIO.writeData(path: path, data: data, atomically: true)
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws {
    @Dependency(\.fileIO) var fileIO
    if createIntermediateDirectories {
      let dir = (path as NSString).deletingLastPathComponent
      try fileIO.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try fileIO.writeString(path: path, content: content, atomically: true, encoding: encoding)
  }

  public func exists(path: String) async throws -> FileExistence {
    @Dependency(\.fileIO) var fileIO
    let (exists, isDir) = fileIO.existsAndIsDirectory(path: path)
    if !exists { return .notFound }
    return isDir ? .directory : .file
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    @Dependency(\.fileIO) var fileIO
    let (dirExists, isDir) = fileIO.existsAndIsDirectory(path: path)
    guard dirExists else { throw RunnerError.fileNotFound(path: path) }
    guard isDir else { throw RunnerError.notADirectory(path: path) }

    let entries = try fileIO.contentsOfDirectory(atPath: path)
    return entries.map { name in
      let full = (path as NSString).appendingPathComponent(name)
      let (_, isEntryDir) = fileIO.existsAndIsDirectory(path: full)
      return DirectoryEntry(name: name, isDirectory: isEntryDir)
    }
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    @Dependency(\.fileIO) var fileIO
    let raw = try fileIO.enumerateDirectory(atPath: root)
    return raw.map { EnumeratedEntry(relativePath: $0.relativePath, absolutePath: $0.absolutePath, isDirectory: $0.isDirectory) }
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    @Dependency(\.fileIO) var fileIO
    try fileIO.createDirectory(atPath: path, withIntermediateDirectories: withIntermediateDirectories)
  }

  // MARK: - Workspace materialization

  public func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    let fm = FileManager.default
    let templatePath = ToolPath.expand(params.templatePath)
    let destinationPath = ToolPath.expand(params.destinationPath)

    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: templatePath, isDirectory: &isDir), isDir.boolValue else {
      throw RunnerError.fileNotFound(path: templatePath)
    }

    // Ensure parent directory exists
    let parentDir = (destinationPath as NSString).deletingLastPathComponent
    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

    do {
      try fm.copyItem(
        at: URL(fileURLWithPath: templatePath),
        to: URL(fileURLWithPath: destinationPath),
      )
    } catch {
      throw RunnerError.requestFailed(
        message: "Failed to copy template: \(templatePath) -> \(destinationPath) (\(error))",
      )
    }

    // Run startup script if provided
    if let script = params.startupScript, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let scriptPath: String = {
        let expanded = ToolPath.expand(script)
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: destinationPath).appendingPathComponent(expanded).path
      }()
      guard fm.fileExists(atPath: scriptPath) else {
        throw RunnerError.requestFailed(message: "Startup script not found: \(scriptPath)")
      }
      let result = try await LocalBash.run(
        command: "bash \(shellEscape(scriptPath))",
        cwd: destinationPath,
        timeoutSeconds: 120,
      )
      if result.exitCode != 0 {
        throw RunnerError.requestFailed(
          message: "Startup script failed (exit \(result.exitCode)): \(result.output)",
        )
      }
    }

    return MaterializeResponse(workspacePath: destinationPath)
  }

  private func shellEscape(_ s: String) -> String {
    if s.isEmpty { return "''" }
    if s.range(of: #"[^A-Za-z0-9_\/\.\-]"#, options: .regularExpression) == nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  // MARK: - Search

  public func find(params: FindParams) async throws -> FindResult {
    @Dependency(\.fileIO) var fileIO

    let searchRoot = params.root
    let (dirExists, isDir) = fileIO.existsAndIsDirectory(path: searchRoot)
    guard dirExists else { throw RunnerError.fileNotFound(path: searchRoot) }
    guard isDir else { throw RunnerError.notADirectory(path: searchRoot) }

    let ignore = GitIgnore(searchRoot: searchRoot, fileIO: fileIO)
    let effectiveLimit = max(1, params.limit)

    let matches = try walkFiles(
      root: searchRoot,
      fileIO: fileIO,
      shouldSkipDescendants: { rel, abs, isDir in
        guard isDir else { return false }
        if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return true }
        return ignore.isIgnored(absolutePath: abs, isDirectory: true)
      },
      include: { rel, abs, isDir in
        if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return false }
        if ignore.isIgnored(absolutePath: abs, isDirectory: isDir) { return false }
        if isDir { return false }
        return ToolGlob.matches(pattern: params.pattern, path: rel, anchored: true)
      },
    )

    let sorted = matches.sorted { $0.lowercased() < $1.lowercased() }
    let limited = Array(sorted.prefix(effectiveLimit))

    return FindResult(
      entries: limited.map { FindEntry(relativePath: $0) },
      totalBeforeLimit: sorted.count,
    )
  }

  public func grep(params: GrepParams) async throws -> GrepResult {
    @Dependency(\.fileIO) var fileIO

    let searchPath = params.root
    let (pathExists, isDir) = fileIO.existsAndIsDirectory(path: searchPath)
    guard pathExists else { throw RunnerError.fileNotFound(path: searchPath) }

    let contextLines = max(0, params.contextLines)
    let effectiveLimit = max(1, params.limit)
    let ignoreCase = params.ignoreCase
    let literal = params.literal

    let rootForRelPaths = isDir ? searchPath : (searchPath as NSString).deletingLastPathComponent
    let ignore = GitIgnore(searchRoot: rootForRelPaths, fileIO: fileIO)

    let files: [String] = if isDir {
      try walkFiles(
        root: searchPath,
        fileIO: fileIO,
        shouldSkipDescendants: { rel, abs, isDir in
          guard isDir else { return false }
          if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return true }
          return ignore.isIgnored(absolutePath: abs, isDirectory: true)
        },
        include: { rel, abs, isDir in
          if rel.hasPrefix(".git/") || rel.hasPrefix("node_modules/") { return false }
          if ignore.isIgnored(absolutePath: abs, isDirectory: isDir) { return false }
          if isDir { return false }
          if let glob = params.glob {
            return ToolGlob.matches(pattern: glob, path: rel, anchored: true)
          }
          return true
        },
      )
      .map { URL(fileURLWithPath: searchPath).appendingPathComponent($0).path }
    } else {
      [searchPath]
    }

    var allMatches: [GrepMatch] = []
    var matchCount = 0
    var matchLimitReached = false
    var linesTruncated = false

    let regex: NSRegularExpression? = {
      if literal { return nil }
      let opts: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
      return try? NSRegularExpression(pattern: params.pattern, options: opts)
    }()

    for file in files {
      if matchCount >= effectiveLimit { break }

      let content: String
      do {
        content = try fileIO.readString(path: file, encoding: .utf8)
      } catch {
        continue
      }

      let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

      func matchesLine(_ line: String) -> Bool {
        if literal {
          if ignoreCase { return line.lowercased().contains(params.pattern.lowercased()) }
          return line.contains(params.pattern)
        }
        guard let regex else { return false }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.firstMatch(in: line, options: [], range: range) != nil
      }

      for (idx, line) in lines.enumerated() {
        if matchCount >= effectiveLimit {
          matchLimitReached = true
          break
        }
        if !matchesLine(line) { continue }
        matchCount += 1

        let rel = ToolGlob.normalize(relativePathForGrep(file: file, root: rootForRelPaths, isDirectoryRoot: isDir))
        let lineNumber = idx + 1

        let start = max(1, lineNumber - contextLines)
        let end = min(lines.count, lineNumber + contextLines)

        for current in start ... end {
          let rawLine = lines[current - 1]
          let (trunc, wasTruncated) = ToolTruncation.truncateLine(rawLine)
          if wasTruncated { linesTruncated = true }
          allMatches.append(GrepMatch(
            file: rel,
            lineNumber: current,
            line: trunc,
            isContext: current != lineNumber,
          ))
        }
      }
    }

    return GrepResult(
      matches: allMatches,
      matchCount: matchCount,
      limitReached: matchLimitReached,
      linesTruncated: linesTruncated,
    )
  }
}
