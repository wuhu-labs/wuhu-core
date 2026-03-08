import Foundation
import Testing
@testable import WuhuCore

/// Comprehensive protocol-level tests for the v3 bash RPC model.
///
/// These tests exercise the BashTagCoordinator and InMemoryRunner
/// without any mux transport — pure protocol-level behavior.
@Suite("Protocol v3: Short-lived Bash RPCs")
struct ProtocolV3BashTests {
  // MARK: - Basic lifecycle

  @Test("Start bash, receive result via callback, verify state transitions")
  func startBashAndReceiveResult() async throws {
    let runner = InMemoryRunner()
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    await runner.stubBash(pattern: "echo hello", result: BashResult(exitCode: 0, output: "hello\n", timedOut: false, terminated: false))

    let result = try await coordinator.runBash(
      tag: "test-1",
      command: "echo hello",
      runner: runner,
      cwd: "/tmp",
      timeout: nil,
    )

    #expect(result.exitCode == 0)
    #expect(result.output == "hello\n")
    #expect(result.terminated == false)
    #expect(result.timedOut == false)
  }

  // MARK: - Cancellation

  @Test("Start bash, cancel before result, verify cancellation")
  func cancelBeforeResult() async throws {
    // Use a runner that never finishes on its own
    let runner = NeverFinishRunner()
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let tag = "cancel-test-1"

    // Start in background
    let bashTask = Task {
      try await coordinator.runBash(
        tag: tag,
        command: "sleep infinity",
        runner: runner,
        cwd: "/tmp",
        timeout: nil,
      )
    }

    // Give time to enter continuation
    try await Task.sleep(for: .milliseconds(50))

    // Cancel
    await coordinator.cancel(tag: tag, runner: runner)

    let result = try await bashTask.value
    #expect(result.terminated == true)
    #expect(result.exitCode == -15)
  }

  @Test("Start bash, cancel after result, verify no-op")
  func cancelAfterResult() async throws {
    let runner = InMemoryRunner()
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    await runner.stubBash(pattern: "echo", result: BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false))

    let result = try await coordinator.runBash(
      tag: "cancel-after-1",
      command: "echo done",
      runner: runner,
      cwd: "/tmp",
      timeout: nil,
    )
    #expect(result.exitCode == 0)

    // Cancel after completion — should be no-op
    await coordinator.cancel(tag: "cancel-after-1", runner: runner)
    // No crash, no error — success
  }

  @Test("Cancel before start — verify tag enters cancelled state, start returns terminated")
  func preCancelBeforeStart() async throws {
    let runner = NeverFinishRunner()
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let tag = "pre-cancel-1"

    // Cancel before start
    await coordinator.cancel(tag: tag, runner: runner)

    // Start should return terminated immediately
    let result = try await coordinator.runBash(
      tag: tag,
      command: "sleep infinity",
      runner: runner,
      cwd: "/tmp",
      timeout: nil,
    )
    #expect(result.terminated == true)
    #expect(result.exitCode == -15)
  }

  // MARK: - Concurrency

  @Test("Multiple concurrent bash calls, results arrive out of order")
  func concurrentCalls() async throws {
    let runner = InMemoryRunner()
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    await runner.stubBash(pattern: "cmd-A", result: BashResult(exitCode: 0, output: "A\n", timedOut: false, terminated: false))
    await runner.stubBash(pattern: "cmd-B", result: BashResult(exitCode: 0, output: "B\n", timedOut: false, terminated: false))
    await runner.stubBash(pattern: "cmd-C", result: BashResult(exitCode: 0, output: "C\n", timedOut: false, terminated: false))

    try await withThrowingTaskGroup(of: (String, BashResult).self) { group in
      for (tag, cmd) in [("t-A", "cmd-A"), ("t-B", "cmd-B"), ("t-C", "cmd-C")] {
        group.addTask {
          let r = try await coordinator.runBash(tag: tag, command: cmd, runner: runner, cwd: "/tmp", timeout: nil)
          return (tag, r)
        }
      }

      var results: [String: String] = [:]
      for try await (tag, result) in group {
        results[tag] = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      #expect(results["t-A"] == "A")
      #expect(results["t-B"] == "B")
      #expect(results["t-C"] == "C")
    }
  }

  // MARK: - Idempotency

  @Test("Idempotent startBash: call startBash twice with same tag, verify only one bash process")
  func idempotentStartBash() async throws {
    let runner = InMemoryRunner()
    await runner.stubBash(pattern: "echo", result: BashResult(exitCode: 0, output: "ok\n", timedOut: false, terminated: false))

    let first = try await runner.startBash(tag: "dup-1", command: "echo 1", cwd: "/tmp", timeout: nil)
    #expect(first.alreadyRunning == false)

    let second = try await runner.startBash(tag: "dup-1", command: "echo 2", cwd: "/tmp", timeout: nil)
    #expect(second.alreadyRunning == true)
  }

  // MARK: - Output chunks

  @Test("Bash output chunks are collected by coordinator")
  func outputChunksCollected() async throws {
    let coordinator = BashTagCoordinator()

    // Simulate output chunks arriving
    try await coordinator.bashOutput(tag: "chunk-1", chunk: "line 1\n")
    try await coordinator.bashOutput(tag: "chunk-1", chunk: "line 2\n")

    let chunks = await coordinator.getOutputChunks(tag: "chunk-1")
    #expect(chunks.count == 2)
    #expect(chunks[0] == "line 1\n")
    #expect(chunks[1] == "line 2\n")
  }

  // MARK: - Cancel status codes

  @Test("cancelBash returns cancelled for running tag")
  func cancelBashReturnsCancelled() async throws {
    let runner = NeverFinishRunner()
    _ = try await runner.startBash(tag: "running-1", command: "sleep", cwd: "/tmp", timeout: nil)
    let result = try await runner.cancelBash(tag: "running-1")
    #expect(result == .cancelled)
  }

  @Test("cancelBash returns notFound for unknown tag")
  func cancelBashReturnsNotFound() async throws {
    let runner = NeverFinishRunner()
    let result = try await runner.cancelBash(tag: "nonexistent")
    #expect(result == .notFound)
  }

  // MARK: - Edge cases

  @Test("bashFinished before runBash registers continuation — result is not lost")
  func resultBeforeContinuation() async throws {
    let coordinator = BashTagCoordinator()
    let runner = InMemoryRunner()
    await runner.setCallbacks(coordinator)

    // Deliver result BEFORE runBash is called
    let earlyResult = BashResult(exitCode: 42, output: "early\n", timedOut: false, terminated: false)
    try await coordinator.bashFinished(tag: "early-1", result: earlyResult)

    // Stub the runner so startBash succeeds but doesn't deliver a second result
    await runner.stubBash(pattern: "cmd", result: BashResult(exitCode: 99, output: "late\n", timedOut: false, terminated: false))

    // runBash should pick up the buffered early result
    let result = try await coordinator.runBash(
      tag: "early-1",
      command: "cmd",
      runner: runner,
      cwd: "/tmp",
      timeout: nil,
    )
    #expect(result.exitCode == 42)
    #expect(result.output == "early\n")
  }
}

// MARK: - NeverFinishRunner

/// A runner whose bash processes never complete on their own.
/// Used to test cancellation flows.
private actor NeverFinishRunner: Runner {
  nonisolated let id: RunnerID = .local
  private var activeTags: Set<String> = []
  private var callbacks: (any RunnerCallbacks)?

  func setCallbacks(_ cb: any RunnerCallbacks) async {
    callbacks = cb
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTags.contains(tag) {
      return BashStarted(tag: tag, alreadyRunning: true)
    }
    activeTags.insert(tag)
    // Never delivers a result — process "runs forever"
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> BashCancelResult {
    if activeTags.remove(tag) != nil {
      return .cancelled
    }
    return .notFound
  }

  func readData(path: String) async throws -> Data {
    throw RunnerError.fileNotFound(path: path)
  }

  func readString(path: String, encoding _: String.Encoding) async throws -> String {
    throw RunnerError.fileNotFound(path: path)
  }

  func writeData(path _: String, data _: Data, createIntermediateDirectories _: Bool) async throws {}
  func writeString(path _: String, content _: String, createIntermediateDirectories _: Bool, encoding _: String.Encoding) async throws {}
  func exists(path _: String) async throws -> FileExistence {
    .notFound
  }

  func listDirectory(path _: String) async throws -> [DirectoryEntry] {
    []
  }

  func enumerateDirectory(root _: String) async throws -> [EnumeratedEntry] {
    []
  }

  func createDirectory(path _: String, withIntermediateDirectories _: Bool) async throws {}
  func find(params _: FindParams) async throws -> FindResult {
    FindResult(entries: [], totalBeforeLimit: 0)
  }

  func grep(params _: GrepParams) async throws -> GrepResult {
    GrepResult(matches: [], matchCount: 0, limitReached: false, linesTruncated: false)
  }

  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    MaterializeResponse(workspacePath: params.destinationPath)
  }
}
