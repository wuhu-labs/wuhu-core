import Foundation
import PiAI

/// Closure that resolves the current working directory for the session.
/// Returns nil when no mount has been set yet.
public typealias CwdProvider = @Sendable () async throws -> String?

public extension AgentTools {
  static func codingAgentTools(
    cwdProvider: @escaping CwdProvider,
    mountResolver: @escaping MountResolver,
    asyncBash: AsyncBashToolContext = .init(),
    braveSearchAPIKey: String? = nil,
  ) -> [AnyAgentTool] {
    var tools: [AnyAgentTool] = [
      readTool(mountResolver: mountResolver),
      writeTool(mountResolver: mountResolver),
      editTool(mountResolver: mountResolver),
      lsTool(mountResolver: mountResolver),
      findTool(mountResolver: mountResolver),
      grepTool(mountResolver: mountResolver),
      bashTool(mountResolver: mountResolver),
      asyncBashTool(cwdProvider: cwdProvider, context: asyncBash),
      asyncBashStatusTool(context: asyncBash),
    ]
    if let braveSearchAPIKey, !braveSearchAPIKey.isEmpty {
      tools.append(webSearchTool(apiKey: braveSearchAPIKey))
    }
    tools.append(copyTool(mountResolver: mountResolver))
    return tools
  }

  /// Create a simple mount resolver for tests.
  /// Wraps a runner + cwd — all tool calls resolve to this runner.
  static func testMountResolver(cwd: String, runner: any Runner = LocalRunner()) -> MountResolver {
    { _ in ResolvedMount(runner: runner, cwd: cwd) }
  }
}

private let noCwdError = "No working directory set. Call the mount tool first — use mount({}) for a scratch directory, or mount({\"path\": \"/some/dir\"}) for a specific directory."

/// Resolve the live cwd, throwing a tool error if nil.
private func requireCwd(_ provider: CwdProvider) async throws -> String {
  guard let cwd = try await provider() else { throw ToolError.message(noCwdError) }
  return cwd
}

/// Resolve a path to an absolute path through the mount resolver.
/// Returns the resolved mount (with runner) and absolute path.
private func resolvePathViaMountOrCwd(
  _ rawPath: String?,
  defaultPath: String = ".",
  mountResolver: MountResolver,
) async throws -> (resolved: ResolvedMount, absolutePath: String) {
  let raw = (rawPath ?? defaultPath).trimmingCharacters(in: .whitespacesAndNewlines)
  let expanded = ToolPath.expand(raw)

  let resolved = try await mountResolver(nil)
  let absPath: String = if expanded.hasPrefix("/") {
    expanded
  } else {
    ToolPath.resolveToCwd(raw, cwd: resolved.cwd)
  }
  return (resolved: resolved, absolutePath: absPath)
}

// MARK: - read

private func readTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String
    var offset: Int?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      // HACK: Silently drop boolean values for offset/limit instead of throwing.
      //
      // We have observed this behavior from both OpenAI GPT-5.2 family (since Wuhu's
      // beginning) and Opus 4.6 (starting from March). In the case of Opus 4.6, the model
      // could poison the context to the point of no return, burning a lot of tokens. Before
      // we ship a proper tool-fix tool, let's do this hack to suppress it.
      let sanitized: JSONValue = if case var .object(obj) = args {
        {
          for key in ["offset", "limit"] {
            if case .bool = obj[key] { obj.removeValue(forKey: key) }
          }
          return JSONValue.object(obj)
        }()
      } else {
        args
      }

      let a = try ToolArgs(toolName: toolName, args: sanitized)
      let path = try a.requireString("path")
      let offset = try a.optionalInt("offset")
      let limit = try a.optionalInt("limit")
      return .init(path: path, offset: offset, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object([
        "type": .string("string"),
        "description": .string("Path to the file to read (relative or absolute)"),
      ]),
      "offset": .object([
        "type": .string("integer"),
        "minimum": .number(1),
        "description": .string(
          "(Optional) 1-indexed line number to start reading from. IMPORTANT: must be an integer JSON number, not true/false. Example: 2001",
        ),
      ]),
      "limit": .object([
        "type": .string("integer"),
        "minimum": .number(1),
        "description": .string(
          "(Optional) Maximum number of lines to read. IMPORTANT: must be an integer JSON number, not true/false. Example: 2000",
        ),
      ]),
    ]),
    "required": .array([.string("path")]),
    "additionalProperties": .bool(false),
  ])

  let description = [
    "Read the contents of a text file.",
    "Output is truncated to \(ToolTruncation.defaultMaxLines) lines or \(ToolTruncation.defaultMaxBytes / 1024)KB (whichever is hit first).",
    "",
    "Pagination:",
    "- offset: integer (1-indexed). The first line number to return.",
    "- limit: integer. The maximum number of lines to return.",
    "",
    "IMPORTANT:",
    "- offset/limit MUST be integers (JSON numbers), not booleans or strings.",
    "- To continue after truncation, copy the exact number from the tool output notice.",
    "  Example: if the output says \"Use offset=2001 to continue\", call read with {\"path\":\"<same file>\",\"offset\":2001}.",
    "",
    "Image files (png, jpg, jpeg, gif, webp) are returned as image content blocks.",
  ].joined(separator: "\n")

  let tool = Tool(name: "read", description: description, parameters: schema)

  return AnyAgentTool(tool: tool, label: "read") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)

    let (mount, resolved) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    let runner = mount.runner

    // Check if the file is an image — return as image content block.
    let ext = (resolved as NSString).pathExtension.lowercased()
    if BlobBucket.isImageExtension(ext) {
      guard let mimeType = BlobBucket.mimeTypeForExtension(ext) else {
        throw ToolError.message("Unsupported image format: \(ext)")
      }
      let fileData = try await runner.readData(path: resolved)
      guard fileData.count <= BlobBucket.maxImageFileSize else {
        throw ToolError.message(
          "Image file too large: \(ToolTruncation.formatSize(fileData.count)). Max supported: \(ToolTruncation.formatSize(BlobBucket.maxImageFileSize))",
        )
      }
      let base64 = fileData.base64EncodedString()
      return AgentToolResult(
        content: [.image(.init(data: base64, mimeType: mimeType))],
        details: .object(["type": .string("image"), "mimeType": .string(mimeType), "size": .number(Double(fileData.count))]),
      )
    }

    let raw = try await runner.readString(path: resolved, encoding: .utf8)
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let allLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let totalLines = allLines.count

    let startLine = max(0, (params.offset ?? 1) - 1)
    if startLine >= totalLines {
      throw ToolError.message("Offset \(params.offset ?? 1) is beyond end of file (\(totalLines) lines total)")
    }

    // Apply a default page size when no explicit limit is set.
    let effectiveLimit = params.limit ?? ToolTruncation.defaultMaxLines
    let end = min(startLine + max(0, effectiveLimit), totalLines)
    let selected = Array(allLines[startLine ..< end])
    let shownLines = end - startLine

    var outputText = selected.joined(separator: "\n")

    // Add pagination continuation notice when there are more lines.
    if startLine + shownLines < totalLines {
      let remaining = totalLines - (startLine + shownLines)
      let nextOffset = startLine + shownLines + 1
      outputText += "\n\n[\(remaining) more lines in file. Use offset=\(nextOffset) to continue.]"
    }

    // Content truncation is handled by the execution layer (ToolResultTruncation).
    return AgentToolResult(
      content: [.text(outputText)],
      details: .object([:]),
    )
  }
}

// MARK: - write

private func writeTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String
    var content: String

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.requireString("path")
      let content = try a.requireString("content")
      return .init(path: path, content: content)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Path to the file to write (relative or absolute)")]),
      "content": .object(["type": .string("string"), "description": .string("Content to write to the file")]),
    ]),
    "required": .array([.string("path"), .string("content")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "write",
    description: "Write content to a file. Creates parent directories if needed. Overwrites if the file already exists.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "write") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let (mount, abs) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    try await mount.runner.writeString(path: abs, content: params.content, createIntermediateDirectories: true, encoding: .utf8)

    let bytes = params.content.utf8.count
    return AgentToolResult(content: [.text("Successfully wrote \(bytes) bytes to \(params.path)")], details: .object([:]))
  }
}

// MARK: - edit

private func editTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String
    var oldText: String
    var newText: String

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.requireString("path")
      let oldText = try a.requireString("oldText")
      let newText = try a.requireString("newText")
      return .init(path: path, oldText: oldText, newText: newText)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Path to the file to edit (relative or absolute)")]),
      "oldText": .object(["type": .string("string"), "description": .string("Exact text to find and replace (must match exactly; minor whitespace/quote differences are tolerated)")]),
      "newText": .object(["type": .string("string"), "description": .string("New text to replace the old text with")]),
    ]),
    "required": .array([.string("path"), .string("oldText"), .string("newText")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "edit",
    description: "Edit a file by replacing a unique text span. Prefers exact match, then applies a fuzzy normalization (trailing whitespace, smart quotes, unicode dashes/spaces). Preserves original line endings and UTF-8 BOM.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "edit") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let (mount, abs) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    let runner = mount.runner

    // Read via Data to preserve UTF-8 BOM (String(contentsOf:) may strip it).
    let rawData = try await runner.readData(path: abs)
    let raw = String(decoding: rawData, as: UTF8.self)
    let (bom, contentNoBom) = stripBom(raw)
    let originalEnding = detectLineEnding(contentNoBom)

    let normalizedContent = normalizeToLF(contentNoBom)
    let normalizedOldText = normalizeToLF(params.oldText)
    let normalizedNewText = normalizeToLF(params.newText)

    let match = fuzzyFindText(content: normalizedContent, needle: normalizedOldText)
    guard match.found else {
      throw ToolError.message(
        "Could not find the exact text in \(params.path). The old text must match exactly including all whitespace and newlines.",
      )
    }

    let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
    let fuzzyNeedle = normalizeForFuzzyMatch(normalizedOldText)
    let occurrences = fuzzyContent.components(separatedBy: fuzzyNeedle).count - 1
    if occurrences > 1 {
      throw ToolError.message(
        "Found \(occurrences) occurrences of the text in \(params.path). The text must be unique. Please provide more context to make it unique.",
      )
    }

    let baseContent = match.contentForReplacement
    let range = match.range
    let newContent = baseContent.replacingCharacters(in: range, with: normalizedNewText)

    if baseContent == newContent {
      throw ToolError.message(
        "No changes made to \(params.path). The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.",
      )
    }

    let firstChangedLine = 1 + baseContent[..<range.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count - 1
    let final = bom + restoreLineEndings(newContent, ending: originalEnding)
    try await runner.writeString(path: abs, content: final, createIntermediateDirectories: false, encoding: .utf8)

    let diff = formatSimpleDiff(oldText: normalizedOldText, newText: normalizedNewText, line: firstChangedLine)
    return AgentToolResult(
      content: [.text("Successfully replaced text in \(params.path).")],
      details: .object([
        "diff": .string(diff),
        "firstChangedLine": .number(Double(firstChangedLine)),
      ]),
    )
  }
}

// MARK: - ls

private func lsTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var path: String?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let path = try a.optionalString("path")
      let limit = try a.optionalInt("limit")
      return .init(path: path, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "path": .object(["type": .string("string"), "description": .string("Directory to list (default: current directory)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of entries to return (default: 500)")]),
    ]),
    "required": .array([]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "ls",
    description: "List directory contents (includes dotfiles). Returns entries sorted alphabetically, with '/' suffix for directories. Truncated to 500 entries or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "ls") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let effectiveLimit = max(1, params.limit ?? 500)
    let (mount, dirPath) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    let dirEntries = try await mount.runner.listDirectory(path: dirPath)

    let sorted = dirEntries.sorted { $0.name.lowercased() < $1.name.lowercased() }

    var results: [String] = []
    results.reserveCapacity(min(sorted.count, effectiveLimit))

    var entryLimitReached = false
    for entry in sorted {
      if results.count >= effectiveLimit {
        entryLimitReached = true
        break
      }
      results.append(entry.isDirectory ? "\(entry.name)/" : entry.name)
    }

    if results.isEmpty {
      return AgentToolResult(content: [.text("(empty directory)")], details: .object([:]))
    }

    var output = results.joined(separator: "\n")

    if entryLimitReached {
      output = "[\(effectiveLimit) entries limit reached. Use limit=\(effectiveLimit * 2) for more]\n\n" + output
    }

    let details: JSONValue = entryLimitReached
      ? .object(["entryLimitReached": .number(Double(effectiveLimit))])
      : .object([:])
    return AgentToolResult(content: [.text(output)], details: details)
  }
}

// MARK: - find

private func findTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var pattern: String
    var path: String?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let pattern = try a.requireString("pattern")
      let path = try a.optionalString("path")
      let limit = try a.optionalInt("limit")
      return .init(pattern: pattern, path: path, limit: limit)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "pattern": .object(["type": .string("string"), "description": .string("Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'")]),
      "path": .object(["type": .string("string"), "description": .string("Directory to search in (default: current directory)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of results (default: 1000)")]),
    ]),
    "required": .array([.string("pattern")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "find",
    description: "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects basic .gitignore patterns. Truncated to 1000 results or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "find") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let effectiveLimit = max(1, params.limit ?? 1000)
    let (mount, searchRoot) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    let findResult = try await mount.runner.find(params: FindParams(root: searchRoot, pattern: params.pattern, limit: effectiveLimit))

    let limited = findResult.entries.map(\.relativePath)

    if limited.isEmpty {
      return AgentToolResult(content: [.text("No files found matching pattern")], details: .object([:]))
    }

    let resultLimitReached = findResult.totalBeforeLimit > effectiveLimit
    var output = limited.joined(separator: "\n")

    if resultLimitReached {
      output = "[\(effectiveLimit) results limit reached. Use limit=\(effectiveLimit * 2) for more, or refine pattern]\n\n" + output
    }

    let details: JSONValue = resultLimitReached
      ? .object(["resultLimitReached": .number(Double(effectiveLimit))])
      : .object([:])
    return AgentToolResult(content: [.text(output)], details: details)
  }
}

// MARK: - grep

private func grepTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var pattern: String
    var path: String?
    var glob: String?
    var ignoreCase: Bool?
    var literal: Bool?
    var context: Int?
    var limit: Int?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let pattern = try a.requireString("pattern")
      let path = try a.optionalString("path")
      let glob = try a.optionalString("glob")
      let ignoreCase = try a.optionalBool("ignoreCase")
      let literal = try a.optionalBool("literal")
      let context = try a.optionalInt("context")
      let limit = try a.optionalInt("limit")
      return .init(
        pattern: pattern,
        path: path,
        glob: glob,
        ignoreCase: ignoreCase,
        literal: literal,
        context: context,
        limit: limit,
      )
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "pattern": .object(["type": .string("string"), "description": .string("Search pattern (regex or literal string)")]),
      "path": .object(["type": .string("string"), "description": .string("Directory or file to search (default: current directory)")]),
      "glob": .object(["type": .string("string"), "description": .string("Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'")]),
      "ignoreCase": .object(["type": .string("boolean"), "description": .string("Case-insensitive search (default: false)")]),
      "literal": .object(["type": .string("boolean"), "description": .string("Treat pattern as literal string instead of regex (default: false)")]),
      "context": .object(["type": .string("number"), "description": .string("Number of lines to show before and after each match (default: 0)")]),
      "limit": .object(["type": .string("number"), "description": .string("Maximum number of matches to return (default: 100)")]),
    ]),
    "required": .array([.string("pattern")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "grep",
    description: "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects basic .gitignore patterns. Truncated to 100 matches or \(ToolTruncation.defaultMaxBytes / 1024)KB.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "grep") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    let contextLines = max(0, params.context ?? 0)
    let effectiveLimit = max(1, params.limit ?? 100)
    let ignoreCase = params.ignoreCase ?? false
    let literal = params.literal ?? false

    let (mount, searchPath) = try await resolvePathViaMountOrCwd(params.path, mountResolver: mountResolver)
    let grepResult = try await mount.runner.grep(params: GrepParams(
      root: searchPath,
      pattern: params.pattern,
      glob: params.glob,
      ignoreCase: ignoreCase,
      literal: literal,
      contextLines: contextLines,
      limit: effectiveLimit,
    ))

    if grepResult.matchCount == 0 {
      return AgentToolResult(content: [.text("No matches found")], details: .object([:]))
    }

    // Format output from GrepMatch entries
    var outputLines: [String] = []
    for m in grepResult.matches {
      if m.isContext {
        outputLines.append("\(m.file)-\(m.lineNumber)- \(m.line)")
      } else {
        outputLines.append("\(m.file):\(m.lineNumber): \(m.line)")
      }
    }

    var output = outputLines.joined(separator: "\n")

    var notices: [String] = []
    var details: [String: JSONValue] = [:]

    if grepResult.limitReached {
      notices.append("\(effectiveLimit) matches limit reached. Use limit=\(effectiveLimit * 2) for more, or refine pattern")
      details["matchLimitReached"] = .number(Double(effectiveLimit))
    }
    if grepResult.linesTruncated {
      notices.append("Some lines truncated to \(ToolTruncation.grepMaxLineLength) chars. Use read tool to see full lines")
      details["linesTruncated"] = .bool(true)
    }

    if !notices.isEmpty {
      output = "[\(notices.joined(separator: ". "))]\n\n" + output
    }

    return AgentToolResult(content: [.text(output)], details: details.isEmpty ? .object([:]) : .object(details))
  }
}

// MARK: - bash

private func bashTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var command: String
    var timeout: Double?
    var mount: String?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let command = try a.requireString("command")
      let timeout = try a.optionalDouble("timeout")
      let mount = try a.optionalString("mount")
      return .init(command: command, timeout: timeout, mount: mount)
    }
  }

  let properties: [String: JSONValue] = [
    "command": .object(["type": .string("string"), "description": .string("Bash command to execute")]),
    "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (optional, no default timeout)")]),
    "mount": .object(["type": .string("string"), "description": .string("Mount name to execute on (optional, defaults to primary mount)")]),
  ]

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(properties),
    "required": .array([.string("command")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "bash",
    description: "Execute a bash command in the current working directory. Returns stdout and stderr (combined). Output is truncated to last \(ToolTruncation.defaultMaxLines) lines or \(ToolTruncation.defaultMaxBytes / 1024)KB. Optionally provide a timeout in seconds.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "bash", truncationDirection: .tail) { toolCallId, args in
    let params = try Params.parse(toolName: tool.name, args: args)

    // All bash execution goes through a runner (local or remote) via mount resolver.
    // When there's no mount and no session cwd, the resolver returns a fallback with
    // cwd "/" and mount nil. Bash requires a real working directory.
    let resolved = try await mountResolver(params.mount)
    guard resolved.mount != nil || resolved.cwd != "/" else {
      throw ToolError.message(noCwdError)
    }
    let runner = resolved.runner

    // Fire-and-forget: start bash and return immediately.
    // Result will arrive via bashFinished callback → bashResultDelivered action.
    _ = try await runner.startBash(
      tag: toolCallId,
      command: params.command,
      cwd: resolved.cwd,
      timeout: params.timeout,
    )

    return .pending
  }
}

// MARK: - async_bash

private func asyncBashTool(cwdProvider: @escaping CwdProvider, context: AsyncBashToolContext) -> AnyAgentTool {
  struct Params: Sendable {
    var command: String
    var timeout: Double?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let command = try a.requireString("command")
      let timeout = try a.optionalDouble("timeout")
      return .init(command: command, timeout: timeout)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "command": .object(["type": .string("string"), "description": .string("Bash command to execute in the background")]),
      "timeout": .object(["type": .string("number"), "description": .string("Timeout in seconds (optional). If set, the process is terminated after this duration.")]),
    ]),
    "required": .array([.string("command")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "async_bash",
    description: "Start a bash command in the background. Returns immediately with a task id. When the task finishes, Wuhu may insert a user-level JSON message into the session transcript.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "async_bash") { _, args in
    let cwd = try await requireCwd(cwdProvider)
    let params = try Params.parse(toolName: tool.name, args: args)
    let started = try await context.registry.start(
      command: params.command,
      cwd: cwd,
      sessionID: context.sessionID,
      ownerID: context.ownerID,
      timeoutSeconds: params.timeout,
    )

    let response: JSONValue = .object([
      "id": .string(started.id),
      "message": .string("Task started. You will receive a message when it finishes; you do not need to wait or poll."),
    ])

    return AgentToolResult(
      content: [.text(wuhuEncodeToolJSON(response))],
      details: .object([
        "id": .string(started.id),
        "pid": .number(Double(started.pid)),
        "started_at": .number(started.startedAt.timeIntervalSince1970),
        "stdout_file": .string(started.stdoutFile),
        "stderr_file": .string(started.stderrFile),
      ]),
    )
  }
}

// MARK: - async_bash_status

private func asyncBashStatusTool(context: AsyncBashToolContext) -> AnyAgentTool {
  struct Params: Sendable {
    var id: String

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let id = try a.requireString("id")
      return .init(id: id)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "id": .object(["type": .string("string"), "description": .string("Task id returned by async_bash")]),
    ]),
    "required": .array([.string("id")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "async_bash_status",
    description: "Query the status of an async_bash task. Returns whether the task is running or finished, plus pid (if running) and stdout/stderr file paths.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "async_bash_status") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)
    guard let status = await context.registry.status(id: params.id) else {
      throw ToolError.message("Unknown async_bash task id: \(params.id)")
    }

    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var obj: [String: JSONValue] = [
      "id": .string(status.id),
      "state": .string(status.state.rawValue),
      "stdout_file": .string(status.stdoutFile),
      "stderr_file": .string(status.stderrFile),
      "started_at": .string(fmt.string(from: status.startedAt)),
      "timed_out": .bool(status.timedOut),
    ]

    if let pid = status.pid {
      obj["pid"] = .number(Double(pid))
    }
    if let endedAt = status.endedAt {
      obj["ended_at"] = .string(fmt.string(from: endedAt))
    }
    if let duration = status.durationSeconds {
      obj["duration_seconds"] = .number(duration)
    }
    if let exitCode = status.exitCode {
      obj["exit_code"] = .number(Double(exitCode))
    }

    let response: JSONValue = .object(obj)
    return AgentToolResult(content: [.text(wuhuEncodeToolJSON(response))], details: response)
  }
}

// MARK: - helpers

private enum ToolError: Error, Sendable, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(m): m
    }
  }
}

// walkFiles is defined in WalkFiles.swift (module-internal).

// relativePathForGrep is defined in WalkFiles.swift (module-internal).

private func stripBom(_ content: String) -> (bom: String, text: String) {
  if content.hasPrefix("\u{FEFF}") {
    return ("\u{FEFF}", String(content.dropFirst()))
  }
  return ("", content)
}

private func detectLineEnding(_ content: String) -> String {
  content.contains("\r\n") ? "\r\n" : "\n"
}

private func normalizeToLF(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func restoreLineEndings(_ text: String, ending: String) -> String {
  ending == "\r\n" ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
}

private func normalizeForFuzzyMatch(_ text: String) -> String {
  let stripped = text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { trimEnd(String($0)) }
    .joined(separator: "\n")

  return stripped
    .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201A}\u{201B}]", with: "'", options: .regularExpression)
    .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201E}\u{201F}]", with: "\"", options: .regularExpression)
    .replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]", with: "-", options: .regularExpression)
    .replacingOccurrences(of: "[\u{00A0}\u{2002}-\u{200A}\u{202F}\u{205F}\u{3000}]", with: " ", options: .regularExpression)
}

private func trimEnd(_ s: String) -> String {
  var end = s.endIndex
  while end > s.startIndex {
    let before = s.index(before: end)
    let ch = s[before]
    if ch == " " || ch == "\t" {
      end = before
      continue
    }
    break
  }
  return String(s[..<end])
}

private struct FuzzyMatch: Sendable {
  var found: Bool
  var range: Range<String.Index>
  var usedFuzzy: Bool
  var contentForReplacement: String
}

private func fuzzyFindText(content: String, needle: String) -> FuzzyMatch {
  if let range = content.range(of: needle) {
    return .init(found: true, range: range, usedFuzzy: false, contentForReplacement: content)
  }

  let fuzzyContent = normalizeForFuzzyMatch(content)
  let fuzzyNeedle = normalizeForFuzzyMatch(needle)
  if let range = fuzzyContent.range(of: fuzzyNeedle) {
    return .init(found: true, range: range, usedFuzzy: true, contentForReplacement: fuzzyContent)
  }

  return .init(found: false, range: content.startIndex ..< content.startIndex, usedFuzzy: false, contentForReplacement: content)
}

private func formatSimpleDiff(oldText: String, newText: String, line: Int) -> String {
  let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
  let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)

  var out: [String] = []
  out.append("@@ line \(line) @@")
  for l in oldLines {
    out.append("-\(l)")
  }
  for l in newLines {
    out.append("+\(l)")
  }
  return out.joined(separator: "\n")
}

private func shellEscape(_ s: String) -> String {
  if s.isEmpty { return "''" }
  if s.range(of: #"[^A-Za-z0-9_\/\.\-]"#, options: .regularExpression) == nil { return s }
  return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// Bash execution is provided by LocalBash (Sources/WuhuCore/LocalBash.swift).
// The bash tool calls LocalBash.run() for local execution and Runner.runBash()
// for remote execution via the mount resolver.

// MARK: - copy tool

private func copyTool(mountResolver: @escaping MountResolver) -> AnyAgentTool {
  struct Params: Sendable {
    var source: String
    var destination: String
    var sourceMount: String?
    var destMount: String?

    static func parse(toolName: String, args: JSONValue) throws -> Params {
      let a = try ToolArgs(toolName: toolName, args: args)
      let source = try a.requireString("source")
      let destination = try a.requireString("destination")
      let sourceMount = try a.optionalString("sourceMount")
      let destMount = try a.optionalString("destMount")
      return .init(source: source, destination: destination, sourceMount: sourceMount, destMount: destMount)
    }
  }

  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "source": .object(["type": .string("string"), "description": .string("Source file path (absolute, or relative to source mount)")]),
      "destination": .object(["type": .string("string"), "description": .string("Destination file path (absolute, or relative to destination mount)")]),
      "sourceMount": .object(["type": .string("string"), "description": .string("Source mount name (optional, defaults to primary mount)")]),
      "destMount": .object(["type": .string("string"), "description": .string("Destination mount name (optional, defaults to primary mount)")]),
    ]),
    "required": .array([.string("source"), .string("destination")]),
    "additionalProperties": .bool(false),
  ])

  let tool = Tool(
    name: "copy",
    description: "Copy a file between mounts (potentially on different runners/machines). For same-runner copies, this is efficient. For cross-runner copies, the file is streamed through the server.",
    parameters: schema,
  )

  return AnyAgentTool(tool: tool, label: "copy") { _, args in
    let params = try Params.parse(toolName: tool.name, args: args)

    let srcResolved = try await mountResolver(params.sourceMount)
    let dstResolved = try await mountResolver(params.destMount)

    // Resolve paths
    let srcPath: String = if params.source.hasPrefix("/") {
      params.source
    } else {
      URL(fileURLWithPath: srcResolved.cwd).appendingPathComponent(params.source).standardizedFileURL.path
    }

    let dstPath: String = if params.destination.hasPrefix("/") {
      params.destination
    } else {
      URL(fileURLWithPath: dstResolved.cwd).appendingPathComponent(params.destination).standardizedFileURL.path
    }

    // Read from source runner, write to destination runner
    let data = try await srcResolved.runner.readData(path: srcPath)
    try await dstResolved.runner.writeData(path: dstPath, data: data, createIntermediateDirectories: true)

    let size = data.count
    let sizeStr = ToolTruncation.formatSize(size)
    return AgentToolResult(
      content: [.text("Copied \(sizeStr) from \(params.source) to \(params.destination)")],
      details: .object([
        "sourcePath": .string(srcPath),
        "destinationPath": .string(dstPath),
        "bytes": .number(Double(size)),
      ]),
    )
  }
}

private extension String {
  func nilIfEqual(_ other: String) -> String? {
    self == other ? nil : self
  }
}
