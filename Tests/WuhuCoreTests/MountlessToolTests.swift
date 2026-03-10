import Dependencies
import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

/// Tests for tool behavior when no mount is set (no primary mount, no session cwd).
///
/// Issue 1: File tools (read, ls, etc.) should work with absolute paths even without a mount.
/// Issue 2: Bash should refuse to run without a mount (it needs a working directory).
@Suite("Mountless Tool Behavior")
struct MountlessToolTests {
  // MARK: - Helpers

  /// Create a mount resolver that simulates "no mount" — returns local runner with "/" cwd and nil mount.
  /// This matches what `MountResolverFactory.make` produces when there's no primary mount and no session cwd.
  private func noMountResolver() -> MountResolver {
    { _ in ResolvedMount(runner: LocalRunner(), cwd: "/", mount: nil) }
  }

  private func noMountTools() -> [String: AnyAgentTool] {
    let resolver = noMountResolver()
    return Dictionary(
      uniqueKeysWithValues: AgentTools.codingAgentTools(
        cwdProvider: { nil },
        mountResolver: resolver,
      ).map { ($0.tool.name, $0) },
    )
  }

  private func textOutput(_ result: ToolExecutionResult) throws -> String {
    let agentResult = try result.unwrapImmediate()
    return agentResult.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  // MARK: - File tools work with absolute paths and no mount

  @Test("read tool works with absolute path and no mount")
  func readAbsolutePathNoMount() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: "/somewhere")
    io.seedFile(path: "/somewhere/test.txt", content: "hello from absolute path")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(noMountTools()["read"])
      let result = try await t.execute(
        toolCallId: "r1",
        args: .object(["path": .string("/somewhere/test.txt")]),
      )
      let out = try textOutput(result)
      #expect(out.contains("hello from absolute path"))
    }
  }

  @Test("ls tool works with absolute path and no mount")
  func lsAbsolutePathNoMount() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: "/mydir")
    io.seedFile(path: "/mydir/file1.txt", content: "a")
    io.seedFile(path: "/mydir/file2.txt", content: "b")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(noMountTools()["ls"])
      let result = try await t.execute(
        toolCallId: "l1",
        args: .object(["path": .string("/mydir")]),
      )
      let out = try textOutput(result)
      #expect(out.contains("file1.txt"))
      #expect(out.contains("file2.txt"))
    }
  }

  // MARK: - Bash refuses without a mount

  @Test("bash tool throws when no mount is set")
  func bashRefusesWithoutMount() async throws {
    let t = try #require(noMountTools()["bash"])
    await #expect(throws: Error.self) {
      _ = try await t.execute(
        toolCallId: "b1",
        args: .object(["command": .string("echo hello")]),
      )
    }
  }
}
