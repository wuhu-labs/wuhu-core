import Dependencies
import Foundation
import Testing
import WuhuCore

/// Tests for the filesystem-based coding agent tools using ``InMemoryFileIO``.
/// These exercise the read, write, edit, ls, find, and grep tools without
/// touching the real filesystem.
struct InMemoryFileIOToolTests {
  private let cwd = "/workspace"

  private func makeIO() -> InMemoryFileIO {
    let io = InMemoryFileIO()
    io.seedDirectory(path: cwd)
    return io
  }

  private func tools() -> [String: AnyAgentTool] {
    Dictionary(
      uniqueKeysWithValues:
      WuhuTools.codingAgentTools(cwd: cwd)
        .map { ($0.tool.name, $0) },
    )
  }

  private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  // MARK: - read tool

  @Test func readFileNotFound() async throws {
    let io = makeIO()
    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "r1", args: .object(["path": .string("missing.txt")]))
      }
    }
  }

  @Test func readSimpleFile() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/hello.txt", content: "Hello, world!\nLine 2\nLine 3")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "r2", args: .object(["path": .string("hello.txt")]))
      let out = textOutput(result)
      #expect(out == "Hello, world!\nLine 2\nLine 3")
    }
  }

  @Test func readLargeFileTruncatesByLines() async throws {
    let io = makeIO()
    let lines = (1 ... 2500).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/large.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "r3", args: .object(["path": .string("large.txt")]))
      let out = textOutput(result)
      #expect(out.contains("Line 1"))
      #expect(out.contains("Line 2000"))
      #expect(!out.contains("Line 2001"))
      #expect(out.contains("Use offset=2001"))
    }
  }

  @Test func readOffsetAndLimit() async throws {
    let io = makeIO()
    let lines = (1 ... 100).map { "Line \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/paginate.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(
        toolCallId: "r4",
        args: .object(["path": .string("paginate.txt"), "offset": .number(41), "limit": .number(20)]),
      )
      let out = textOutput(result)
      #expect(!out.contains("Line 40\n"))
      #expect(out.contains("Line 41"))
      #expect(out.contains("Line 60"))
      #expect(!out.contains("Line 61"))
      #expect(out.contains("40 more lines"))
      #expect(out.contains("Use offset=61"))
    }
  }

  @Test func readOffsetBeyondEnd() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/short.txt", content: "Line 1\nLine 2")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "r5", args: .object(["path": .string("short.txt"), "offset": .number(100)]))
      }
    }
  }

  @Test func readImageDetection() async throws {
    let io = makeIO()
    let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    io.seedFile(path: "\(cwd)/image.png", data: pngData)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let result = try await t.execute(toolCallId: "r6", args: .object(["path": .string("image.png")]))
      #expect(result.content.count == 1)
      guard case let .image(img) = result.content.first else {
        Issue.record("Expected image content block")
        return
      }
      #expect(img.mimeType == "image/png")
      #expect(Data(base64Encoded: img.data) == pngData)
    }
  }

  // MARK: - write tool

  @Test func writeCreatesParentDirs() async throws {
    let io = makeIO()
    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["write"])
      let result = try await t.execute(
        toolCallId: "w1",
        args: .object(["path": .string("nested/dir/file.txt"), "content": .string("hello")]),
      )
      #expect(textOutput(result).contains("Successfully wrote"))
      let stored = io.storedString(path: "\(cwd)/nested/dir/file.txt")
      #expect(stored == "hello")
    }
  }

  @Test func writeOverwritesExisting() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/existing.txt", content: "old content")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["write"])
      _ = try await t.execute(
        toolCallId: "w2",
        args: .object(["path": .string("existing.txt"), "content": .string("new content")]),
      )
      #expect(io.storedString(path: "\(cwd)/existing.txt") == "new content")
    }
  }

  // MARK: - edit tool

  @Test func editExactMatch() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/edit.txt", content: "Hello, world!\nLine 2\nLine 3")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      _ = try await t.execute(toolCallId: "e1", args: .object([
        "path": .string("edit.txt"),
        "oldText": .string("Hello, world!"),
        "newText": .string("Hi"),
      ]))
      #expect(io.storedString(path: "\(cwd)/edit.txt") == "Hi\nLine 2\nLine 3")
    }
  }

  @Test func editFuzzyMatchTrailingWhitespace() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/fuzzy.txt", content: "line one   \nline two  \nline three\n")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      _ = try await t.execute(toolCallId: "e2", args: .object([
        "path": .string("fuzzy.txt"),
        "oldText": .string("line one\nline two\n"),
        "newText": .string("replaced\n"),
      ]))
      #expect(io.storedString(path: "\(cwd)/fuzzy.txt") == "replaced\nline three\n")
    }
  }

  @Test func editNoMatchThrows() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/nomatch.txt", content: "Hello, world!")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "e3", args: .object([
          "path": .string("nomatch.txt"),
          "oldText": .string("nope"),
          "newText": .string("x"),
        ]))
      }
    }
  }

  @Test func editMultipleMatchesThrows() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/dups.txt", content: "foo foo foo")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "e4", args: .object([
          "path": .string("dups.txt"),
          "oldText": .string("foo"),
          "newText": .string("bar"),
        ]))
      }
    }
  }

  @Test func editFileNotFoundThrows() async throws {
    let io = makeIO()
    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["edit"])
      await #expect(throws: Error.self) {
        _ = try await t.execute(toolCallId: "e5", args: .object([
          "path": .string("missing.txt"),
          "oldText": .string("x"),
          "newText": .string("y"),
        ]))
      }
    }
  }

  // MARK: - ls tool

  @Test func lsEmptyDirectory() async throws {
    let io = makeIO()
    io.seedDirectory(path: "\(cwd)/empty")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["ls"])
      let result = try await t.execute(toolCallId: "l1", args: .object(["path": .string("empty")]))
      #expect(textOutput(result) == "(empty directory)")
    }
  }

  @Test func lsSortedOutput() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/banana.txt", content: "b")
    io.seedFile(path: "\(cwd)/apple.txt", content: "a")
    io.seedFile(path: "\(cwd)/cherry.txt", content: "c")
    io.seedDirectory(path: "\(cwd)/dir1")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["ls"])
      let result = try await t.execute(toolCallId: "l2", args: .object(["path": .string(".")]))
      let out = textOutput(result)
      let lines = out.split(separator: "\n").map(String.init)
      #expect(lines.contains("apple.txt"))
      #expect(lines.contains("banana.txt"))
      #expect(lines.contains("cherry.txt"))
      #expect(lines.contains("dir1/"))
    }
  }

  @Test func lsLimit() async throws {
    let io = makeIO()
    for i in 1 ... 10 {
      io.seedFile(path: "\(cwd)/file\(String(format: "%02d", i)).txt", content: "\(i)")
    }

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["ls"])
      let result = try await t.execute(toolCallId: "l3", args: .object(["path": .string("."), "limit": .number(3)]))
      let out = textOutput(result)
      #expect(out.contains("entries limit reached"))
      let fileLines = out.split(separator: "\n").filter { !$0.hasPrefix("[") }
      #expect(fileLines.count == 3)
    }
  }

  // MARK: - find tool

  @Test func findGlobMatching() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/src/main.swift", content: "import Foundation")
    io.seedFile(path: "\(cwd)/src/helper.swift", content: "func help() {}")
    io.seedFile(path: "\(cwd)/README.md", content: "# README")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["find"])
      let result = try await t.execute(
        toolCallId: "f1",
        args: .object(["pattern": .string("**/*.swift"), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("src/main.swift"))
      #expect(out.contains("src/helper.swift"))
      #expect(!out.contains("README.md"))
    }
  }

  @Test func findRespectsGitignore() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/.gitignore", content: "ignored.txt\n")
    io.seedFile(path: "\(cwd)/visible.txt", content: "visible")
    io.seedFile(path: "\(cwd)/ignored.txt", content: "ignored")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["find"])
      let result = try await t.execute(
        toolCallId: "f2",
        args: .object(["pattern": .string("**/*.txt"), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("visible.txt"))
      #expect(!out.contains("ignored.txt"))
    }
  }

  // MARK: - grep tool

  @Test func grepRegex() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/code.swift", content: "let x = 42\nlet y = 99\nvar z = 0")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g1",
        args: .object(["pattern": .string("let [a-z]"), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("let x"))
      #expect(out.contains("let y"))
      #expect(!out.contains("var z"))
    }
  }

  @Test func grepLiteral() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/data.txt", content: "foo.bar\nfoo*bar\nbaz")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g2",
        args: .object(["pattern": .string("foo*bar"), "literal": .bool(true), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("foo*bar"))
      let lines = out.split(separator: "\n").filter { $0.contains("data.txt:") }
      #expect(lines.count == 1)
    }
  }

  @Test func grepCaseInsensitive() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/mixed.txt", content: "Hello\nhello\nHELLO\nworld")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g3",
        args: .object(["pattern": .string("hello"), "ignoreCase": .bool(true), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("Hello"))
      #expect(out.contains("hello"))
      #expect(out.contains("HELLO"))
      #expect(!out.contains("world"))
    }
  }

  @Test func grepContextLines() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/ctx.txt", content: "aaa\nbbb\nccc\nddd\neee")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g4",
        args: .object(["pattern": .string("ccc"), "context": .number(1), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("bbb"))
      #expect(out.contains("ccc"))
      #expect(out.contains("ddd"))
      #expect(!out.contains("aaa"))
      #expect(!out.contains("eee"))
    }
  }

  @Test func grepNoMatches() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/nope.txt", content: "nothing to see here")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g5",
        args: .object(["pattern": .string("xyz"), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out == "No matches found")
    }
  }

  @Test func grepLimit() async throws {
    let io = makeIO()
    let lines = (1 ... 20).map { "match \($0)" }.joined(separator: "\n")
    io.seedFile(path: "\(cwd)/many.txt", content: lines)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["grep"])
      let result = try await t.execute(
        toolCallId: "g6",
        args: .object(["pattern": .string("match"), "limit": .number(5), "path": .string(".")]),
      )
      let out = textOutput(result)
      #expect(out.contains("matches limit reached"))
      let matchLines = out.split(separator: "\n").filter { $0.contains("many.txt:") }
      #expect(matchLines.count == 5)
    }
  }
}
