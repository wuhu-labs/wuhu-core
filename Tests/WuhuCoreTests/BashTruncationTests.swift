import Dependencies
import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore

/// Tests that bash tool output is truncated when it exceeds the budget.
///
/// The bash tool returns `.pending` and delivers results via callback through
/// `persistDeliveredBashResult`. This test verifies that truncation is applied
/// on that code path (not just for `.immediate` tool results).
@Suite("Bash Output Truncation")
struct BashOutputTruncationTests {
  @Test("bash output is truncated when exceeding budget")
  func bashOutputTruncated() async throws {
    // Create a temp directory for bash to run in.
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-bash-trunc-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cwd = tempDir.path

    // Generate a bash command that produces output exceeding the truncation budget.
    // Default budget is 10,000 chars. Produce ~20,000 chars.
    let lineCount = 1000
    let bashCommand = "for i in $(seq 1 \(lineCount)); do echo \"Line $i: \(String(repeating: "x", count: 15))\"; done"

    // Mock LLM: first call issues bash, second call responds with text after seeing the result.
    let mock = MockStreamFn(responses: [
      .toolCalls([
        MockToolCall(
          id: "tc-bash-trunc",
          name: "bash",
          arguments: .object(["command": .string(bashCommand)]),
        ),
      ]),
      .text("Done."),
    ])

    // Build the harness with a real local runner that has callbacks wired up.
    let store = try SQLiteSessionStore(path: ":memory:")
    let bashCoordinator = BashTagCoordinator()
    let localRunner = LocalRunner()
    let registry = RunnerRegistry(runners: [localRunner])

    // Wire callbacks: LocalRunner → BashTagCoordinator
    await localRunner.setCallbacks(bashCoordinator)

    let service = WuhuService(
      store: store,
      runnerRegistry: registry,
      bashCoordinator: bashCoordinator,
    ) { $0.streamFn = mock.streamFn }
    await service.startAgentLoopManager()

    // Create a session with a real cwd (mount).
    let sessionID = UUID().uuidString.lowercased()
    let session = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock-model",
      systemPrompt: "You are a test assistant.",
      cwd: cwd,
    )

    // Enqueue and wait for the full cycle: user → LLM → bash → result → LLM → text → idle.
    let message = QueuedUserMessage(
      author: .participant(.init(rawValue: "test-user"), kind: .human),
      content: .text("run the command"),
    )
    _ = try await service.enqueue(sessionID: .init(rawValue: session.id), message: message, lane: .followUp)

    let stream = try await service.followSessionStream(
      sessionID: session.id,
      sinceCursor: nil,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: 30,
    )
    for try await event in stream {
      switch event {
      case .idle, .done:
        break
      default:
        continue
      }
      break
    }

    // Check the transcript for the bash tool result.
    let entries = try await store.getEntries(sessionID: session.id)
    let toolResults = entries.compactMap { entry -> WuhuToolResultMessage? in
      guard case let .message(msg) = entry.payload else { return nil }
      guard case let .toolResult(t) = msg else { return nil }
      return t
    }

    let bashResult = try #require(toolResults.first { $0.toolName == "bash" })
    let resultText = bashResult.content.compactMap { block -> String? in
      if case let .text(text: t, signature: _) = block { return t }
      return nil
    }.joined()

    // The output should be truncated — it should NOT contain all lines.
    #expect(!resultText.contains("Line 1:"), "Tail truncation should drop early lines")
    #expect(resultText.contains("Line \(lineCount):"), "Tail truncation should keep the last line")

    // Should contain a truncation notice with line count info.
    #expect(resultText.contains("lines"), "Should have truncation notice mentioning lines")
  }
}
