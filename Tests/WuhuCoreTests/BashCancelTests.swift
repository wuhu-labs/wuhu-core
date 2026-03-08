import Foundation
import Mux
import Testing
@testable import WuhuCore

@Suite("Bash Cancel")
struct BashCancelTests {
  /// Test that cancelBash on InMemoryRunner returns .cancelled for an active tag.
  @Test func cancelActiveTag() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let bridge = BashCallbackBridge()
    await runner.setCallbacks(bridge)

    let tag = "tool-call-123"
    _ = try await runner.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)

    // Give the task a moment to start
    try await Task.sleep(for: .milliseconds(50))

    let result = try await runner.cancelBash(tag: tag)
    #expect(result == .cancelled)
  }

  /// Test that cancelling a non-existent tag returns .notFound.
  @Test func cancelNonExistentTag() async throws {
    let runner = InMemoryRunner()
    let result = try await runner.cancelBash(tag: "does-not-exist")
    #expect(result == .notFound)
  }

  /// Test the BashCallbackBridge cancel flow: cancelWait resumes with CancellationError.
  @Test func callbackBridgeCancelWait() async throws {
    let bridge = BashCallbackBridge()
    let tag = "cancel-bridge-test"

    let waitTask = Task {
      try await bridge.waitForResult(tag: tag)
    }

    // Give the continuation time to register
    try await Task.sleep(for: .milliseconds(50))

    await bridge.cancelWait(tag: tag)

    do {
      _ = try await waitTask.value
      Issue.record("Should have thrown CancellationError")
    } catch {
      #expect(error is CancellationError)
    }
  }

  /// Test the full cancel flow with BashCallbackBridge and withTaskCancellationHandler.
  @Test func taskCancellationTriggersCancelBash() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let bridge = BashCallbackBridge()
    await runner.setCallbacks(bridge)

    let tag = "integration-cancel-tag"

    // Simulate what the bash tool does: startBash + waitForResult with cancellation handler
    let bashTask = Task {
      _ = try await runner.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
      return try await withTaskCancellationHandler {
        try await bridge.waitForResult(tag: tag)
      } onCancel: {
        Task { try? await runner.cancelBash(tag: tag) }
        Task { await bridge.cancelWait(tag: tag) }
      }
    }

    try await Task.sleep(for: .milliseconds(100))

    // Cancel the task (simulates what runtime.stop() does)
    bashTask.cancel()

    do {
      _ = try await bashTask.value
      Issue.record("Should have thrown")
    } catch {
      // CancellationError is expected
      #expect(error is CancellationError)
    }
  }

  /// Test cancel over mux transport using the new protocol.
  @Test("Cancel over mux transport", arguments: TransportKind.allCases)
  func cancelOverMux(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowBashRunner(delay: .seconds(60))
      let bridge = BashCallbackBridge()
      await runner.setCallbacks(bridge)

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, commands: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)
      await client.startCallbackHandler(callbacks: bridge)
      defer { Task { await client.stopCallbackHandler() } }

      let tag = "mux-cancel-789"

      // Start bash via mux
      let started = try await client.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
      #expect(started.tag == tag)

      // Give the runner time to start the task
      try await Task.sleep(for: .milliseconds(200))

      // Cancel via mux
      let cancelResult = try await client.cancelBash(tag: tag)
      #expect(cancelResult == .cancelled)
    }
  }

  /// Test that BashCallbackBridge buffers results that arrive before waitForResult.
  @Test func bridgeBuffersEarlyResult() async throws {
    let bridge = BashCallbackBridge()
    let tag = "early-result"
    let expected = BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false)

    // Result arrives before anyone is waiting
    try await bridge.bashFinished(tag: tag, result: expected)

    // Now wait — should return immediately
    let result = try await bridge.waitForResult(tag: tag)
    #expect(result == expected)
  }
}

// MARK: - SlowBashRunner

/// A test runner where bash calls block for a configurable duration.
/// Implements RunnerCommands with the fire-and-forget startBash pattern.
actor SlowBashRunner: RunnerCommands {
  nonisolated let id: RunnerID = .local
  let delay: Duration
  private var callbacks: (any RunnerCallbacks)?
  private var activeTasks: [String: Task<Void, Never>] = [:]
  private var completedTags: Set<String> = []

  init(delay: Duration) {
    self.delay = delay
  }

  func setCallbacks(_ cb: any RunnerCallbacks) {
    callbacks = cb
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil || completedTags.contains(tag) {
      return BashStarted(tag: tag)
    }

    let delay = delay
    let callbacks = callbacks

    let task = Task<Void, Never> { [weak self] in
      var result: BashResult
      do {
        try await Task.sleep(for: delay)
        result = BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false)
      } catch {
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

// MARK: - MutableFlag

/// Thread-safe flag for testing whether a closure was called.
final class MutableFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = false
  var value: Bool {
    lock.lock(); defer { lock.unlock() }; return _value
  }

  func set() {
    lock.lock(); _value = true; lock.unlock()
  }
}
