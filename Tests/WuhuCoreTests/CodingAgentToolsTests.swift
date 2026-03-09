import Dependencies
import Foundation
import Testing
import WuhuCore

struct CodingAgentToolsTests {
  private let cwd = "/workspace"

  private func makeIO() -> InMemoryFileIO {
    let io = InMemoryFileIO()
    io.seedDirectory(path: cwd)
    return io
  }

  private func tools() -> [String: AnyAgentTool] {
    let resolver = WuhuTools.testMountResolver(cwd: cwd)
    return Dictionary(uniqueKeysWithValues: WuhuTools.codingAgentTools(cwdProvider: { cwd }, mountResolver: resolver).map { ($0.tool.name, $0) })
  }

  private func textOutput(_ result: ToolExecutionResult) throws -> String {
    let agentResult = try result.unwrapImmediate()
    return agentResult.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  /// Real temp directory — only used by bash/swift tests that need process execution.
  private func makeTempDir(prefix: String) throws -> String {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    return dir.path
  }

  /// Real-filesystem tools — only used by bash/swift tests that need process execution.
  private func realTools(cwd: String) -> [String: AnyAgentTool] {
    let resolver = WuhuTools.testMountResolver(cwd: cwd)
    return Dictionary(uniqueKeysWithValues: WuhuTools.codingAgentTools(cwdProvider: { cwd }, mountResolver: resolver).map { ($0.tool.name, $0) })
  }

  // MARK: - read tool

  @Test func readToolReadsFileWithinLimits() async throws {
    let io = makeIO()
    let content = "Hello, world!\nLine 2\nLine 3"
    io.seedFile(path: "\(cwd)/test.txt", content: content)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "t1", args: .object(["path": .string("test.txt")]))
      #expect(try textOutput(result) == content)
    }
  }

  @Test func readToolNonexistentFileThrows() async throws {
    let io = makeIO()
    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "t2", args: .object(["path": .string("missing.txt")]))
      }
    }
  }

  @Test func readToolTruncatesByLineLimit() async throws {
    let io = makeIO()
    let lines = (1 ... 2500).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/large.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "t3", args: .object(["path": .string("large.txt")]))
      let out = try textOutput(result)
      #expect(out.contains("Line 1"))
      #expect(out.contains("Line 2000"))
      #expect(!out.contains("Line 2001"))
      #expect(out.contains("Use offset=2001"))
    }
  }

  @Test func readToolReturnsAllLinesWithinPageSize() async throws {
    let io = makeIO()
    let lines = (1 ... 500).map { "Line \($0): " + String(repeating: "x", count: 200) }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/large-bytes.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "t4", args: .object(["path": .string("large-bytes.txt")]))
      let out = try textOutput(result)
      #expect(out.contains("Line 1:"))
      #expect(out.contains("Line 500:"))
      // All 500 lines fit within the default 2000-line page size.
      // Byte-level truncation is now handled by the execution layer (ToolResultTruncation).
      #expect(!out.contains("Use offset="))
    }
  }

  @Test func readToolOffset() async throws {
    let io = makeIO()
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/offset.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "t5", args: .object(["path": .string("offset.txt"), "offset": .number(51)]))
      let out = try textOutput(result)
      #expect(!out.contains("Line 50"))
      #expect(out.contains("Line 51"))
      #expect(out.contains("Line 100"))
      #expect(!out.contains("Use offset="))
    }
  }

  @Test func readToolLimitAddsContinueNotice() async throws {
    let io = makeIO()
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/limit.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "t6", args: .object(["path": .string("limit.txt"), "limit": .number(10)]))
      let out = try textOutput(result)
      #expect(out.contains("Line 1"))
      #expect(out.contains("Line 10"))
      #expect(!out.contains("Line 11"))
      #expect(out.contains("90 more lines"))
      #expect(out.contains("Use offset=11"))
    }
  }

  @Test func readToolOffsetAndLimit() async throws {
    let io = makeIO()
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/offset-limit.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(
        toolCallId: "t7",
        args: .object(["path": .string("offset-limit.txt"), "offset": .number(41), "limit": .number(20)]),
      )
      let out = try textOutput(result)
      #expect(!out.contains("Line 40"))
      #expect(out.contains("Line 41"))
      #expect(out.contains("Line 60"))
      #expect(!out.contains("Line 61"))
      #expect(out.contains("40 more lines"))
      #expect(out.contains("Use offset=61"))
    }
  }

  @Test func readToolOffsetBeyondLengthThrows() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/short.txt", content: "Line 1\nLine 2\nLine 3")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "t8", args: .object(["path": .string("short.txt"), "offset": .number(100)]))
      }
    }
  }

  @Test func readToolOffsetBoolTrueThrowsHelpfulError() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/test.txt", content: "Line 1\nLine 2\nLine 3")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      do {
        _ = try await t.execute(toolCallId: "t-bool-offset", args: .object([
          "path": .string("test.txt"),
          "offset": .bool(true),
        ]))
        #expect(Bool(false))
      } catch {
        #expect(
          String(describing: error)
            == "read tool expects integer for key path \"offset\", but value \"true\" of boolean received.",
        )
      }
    }
  }

  @Test func readToolOffsetTypeMismatchHasHelpfulError() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/test.txt", content: "Line 1\nLine 2\nLine 3")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      do {
        _ = try await t.execute(toolCallId: "t-mismatch", args: .object([
          "path": .string("test.txt"),
          "offset": .string("true"),
        ]))
        #expect(Bool(false))
      } catch {
        #expect(
          String(describing: error)
            == "read tool expects integer for key path \"offset\", but value \"true\" of string received.",
        )
      }
    }
  }

  // MARK: - write tool

  @Test func writeToolWritesAndCreatesParents() async throws {
    let io = makeIO()
    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["write"])
      let rel = "nested/dir/file.txt"
      let result = try await t.execute(toolCallId: "w1", args: .object(["path": .string(rel), "content": .string("hello")]))
      #expect(try textOutput(result).contains("Successfully wrote"))
      #expect(io.storedString(path: "\(cwd)/nested/dir/file.txt") == "hello")
    }
  }

  // MARK: - edit tool

  @Test func editToolReplacesText() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/edit.txt", content: "Hello, world!")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      _ = try await t.execute(toolCallId: "e1", args: .object([
        "path": .string("edit.txt"),
        "oldText": .string("Hello, world!"),
        "newText": .string("Hi"),
      ]))
      #expect(io.storedString(path: "\(cwd)/edit.txt") == "Hi")
    }
  }

  @Test func editToolFailsIfNotFound() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/edit.txt", content: "Hello, world!")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "e2", args: .object([
          "path": .string("edit.txt"),
          "oldText": .string("nope"),
          "newText": .string("x"),
        ]))
      }
    }
  }

  @Test func editToolFailsIfMultipleOccurrences() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/dups.txt", content: "foo foo foo")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "e3", args: .object([
          "path": .string("dups.txt"),
          "oldText": .string("foo"),
          "newText": .string("bar"),
        ]))
      }
    }
  }

  @Test func editToolFuzzyTrailingWhitespace() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/trailing.txt", content: "line one   \nline two  \nline three\n")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      _ = try await t.execute(toolCallId: "ef1", args: .object([
        "path": .string("trailing.txt"),
        "oldText": .string("line one\nline two\n"),
        "newText": .string("replaced\n"),
      ]))
      #expect(io.storedString(path: "\(cwd)/trailing.txt") == "replaced\nline three\n")
    }
  }

  @Test func editToolPreservesCRLFAndBOM() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/bom.txt", content: "\u{FEFF}first\r\nsecond\r\nthird\r\n")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      _ = try await t.execute(toolCallId: "ef2", args: .object([
        "path": .string("bom.txt"),
        "oldText": .string("second\n"),
        "newText": .string("REPLACED\n"),
      ]))
      let updated = io.storedString(path: "\(cwd)/bom.txt")
      #expect(updated == "\u{FEFF}first\r\nREPLACED\r\nthird\r\n")
    }
  }

  // MARK: - grep tool

  @Test func grepToolSearchesSingleFileWithContextAndLimit() async throws {
    let io = makeIO()
    let content = ["before", "match one", "after", "middle", "match two", "after two"].joined(separator: "\n")
    io.seedFile(path: "\(cwd)/context.txt", content: content)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(toolCallId: "g1", args: .object([
        "pattern": .string("match"),
        "path": .string("\(cwd)/context.txt"),
        "limit": .number(1),
        "context": .number(1),
      ]))
      let out = try textOutput(result)
      #expect(out.contains("context.txt-1- before"))
      #expect(out.contains("context.txt:2: match one"))
      #expect(out.contains("context.txt-3- after"))
      #expect(out.contains("matches limit reached"))
      #expect(!out.contains("match two"))
    }
  }

  // MARK: - find tool

  @Test func findToolIncludesHiddenAndRespectsGitignore() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/.secret/hidden.txt", content: "hidden")
    io.seedFile(path: "\(cwd)/visible.txt", content: "visible")
    io.seedFile(path: "\(cwd)/.gitignore", content: "ignored.txt\n")
    io.seedFile(path: "\(cwd)/ignored.txt", content: "ignored")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["find"])
      let result = try await t.execute(toolCallId: "f1", args: .object([
        "pattern": .string("**/*.txt"),
        "path": .string(cwd),
      ]))
      let out = try textOutput(result).split(separator: "\n").map { String($0) }
      #expect(out.contains("visible.txt"))
      #expect(out.contains(".secret/hidden.txt"))
      #expect(!out.contains("ignored.txt"))
    }
  }

  // MARK: - ls tool

  @Test func lsToolListsDotfilesAndDirectories() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/.hidden-file", content: "secret")
    io.seedDirectory(path: "\(cwd)/.hidden-dir")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["ls"])
      let result = try await t.execute(toolCallId: "l1", args: .object(["path": .string(cwd)]))
      let out = try textOutput(result)
      #expect(out.contains(".hidden-file"))
      #expect(out.contains(".hidden-dir/"))
    }
  }

  // MARK: - bash tool (fire-and-forget pattern)

  //
  // The bash tool now returns `.pending` immediately after starting the command.
  // Results arrive via callback. These tests verify the tool starts commands correctly.

  @Test func bashToolReturnsPending() async throws {
    let dir = try makeTempDir(prefix: "wuhu-bash")
    let t = try #require(realTools(cwd: dir)["bash"])
    let result = try await t.execute(toolCallId: "b1", args: .object(["command": .string("echo 'test output'")]))
    // Bash tool now returns .pending (fire-and-forget)
    guard case .pending = result else {
      Issue.record("Expected .pending, got \(result)")
      return
    }
    // The command will complete asynchronously via callback
  }

  @Test func bashToolTimeoutPassedToRunner() async throws {
    // When timeout is specified, it's passed to the runner
    // The actual timeout behavior is tested in BashCancelTests
    let dir = try makeTempDir(prefix: "wuhu-bash-timeout")
    let t = try #require(realTools(cwd: dir)["bash"])

    // Just verify we can call with timeout (no error during setup)
    let result = try await t.execute(toolCallId: "b2", args: .object(["command": .string("echo hi"), "timeout": .number(60)]))
    guard case .pending = result else {
      Issue.record("Expected .pending, got \(result)")
      return
    }
  }

  /// Test: multiple concurrent bash commands all return pending.
  @Test func bashToolConcurrentStartsAllReturnPending() async throws {
    let dir = try makeTempDir(prefix: "wuhu-bash-concurrent")
    let t = try #require(realTools(cwd: dir)["bash"])

    try await withThrowingTaskGroup(of: ToolExecutionResult.self) { group in
      for i in 0 ..< 5 {
        group.addTask {
          try await t.execute(
            toolCallId: "conc-\(i)",
            args: .object(["command": .string("echo 'run \(i)'")]),
          )
        }
      }
      for try await result in group {
        guard case .pending = result else {
          Issue.record("Expected .pending, got \(result)")
          return
        }
      }
    }
  }
}
