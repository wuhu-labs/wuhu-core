import Foundation
import Mux
import Testing
@testable import WuhuCore

@Suite("Bash Cancel")
struct BashCancelTests {
  /// Test that cancelling a tagged bash via InMemoryRunnerCommands works.
  @Test func cancelTaggedBashInMemory() async throws {
    let runner = InMemoryRunnerCommands()
    // Default stub returns immediately, so we need a slow one.
    // We use cancelBash directly before waitForBashResult.
    let tag = "cancel-test-1"
    _ = try await runner.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
    try await Task.sleep(for: .milliseconds(10))
    let cancel = try await runner.cancelBash(tag: tag)
    #expect(cancel.cancelled)
    let result = try await runner.waitForBashResult(tag: tag)
    #expect(result.terminated)
  }

  /// Test that cancelling a non-existent tag returns cancelled=false.
  @Test func cancelNonExistentTag() async throws {
    let runner = InMemoryRunnerCommands()
    let cancel = try await runner.cancelBash(tag: "does-not-exist")
    #expect(!cancel.cancelled)
  }

  /// Test the full cancel flow over mux transport: startBash + cancelBash.
  @Test("Cancel over mux transport", arguments: TransportKind.allCases)
  func cancelOverMux(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowRunnerCommands(delay: .seconds(60))

      let handlerTask = Task {
        await MuxRunnerCommandsServer.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerCommandsClient(name: "test-runner", session: clientSession)

      let tag = "mux-cancel-test-1"

      // Start bash in background — it will wait for result
      let waitTask = Task {
        _ = try await client.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
        return try await client.waitForBashResult(tag: tag)
      }

      // Give runner time to start processing
      try await Task.sleep(for: .milliseconds(200))

      // Cancel
      let cancelResult = try await client.cancelBash(tag: tag)
      #expect(cancelResult.cancelled)

      // Wait task should complete with terminated=true
      let result = try await waitTask.value
      #expect(result.terminated)
    }
  }

  /// Integration test: withTaskCancellationHandler triggers cancelBash.
  @Test func taskCancellationTriggersCancelBash() async throws {
    let runner = InMemoryRunnerCommands()
    let tag = "integration-cancel-tag"

    // Track whether the cancel handler was called
    let cancelCalled = MutableFlag()

    let bashTask = Task {
      _ = try await runner.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
      return try await withTaskCancellationHandler {
        try await runner.waitForBashResult(tag: tag)
      } onCancel: {
        cancelCalled.set()
        Task { _ = try? await runner.cancelBash(tag: tag) }
      }
    }

    try await Task.sleep(for: .milliseconds(50))

    // Cancel the task
    bashTask.cancel()

    // Either CancellationError or terminated result is acceptable
    do {
      let result = try await bashTask.value
      #expect(result.terminated)
    } catch is CancellationError {
      // Expected
    }

    #expect(cancelCalled.value)
  }
}

// MARK: - SlowRunnerCommands

/// A RunnerCommands implementation where bash suspends for a configurable duration.
private actor SlowRunnerCommands: RunnerCommands {
  nonisolated let id: RunnerID = .local
  let delay: Duration
  private let bridge = BashCallbackBridge()
  private var activeTasks: [String: Task<Void, Never>] = [:]

  init(delay: Duration) {
    self.delay = delay
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil { return BashStarted(tag: tag, alreadyRunning: true) }
    let bridge = bridge
    let delay = delay
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(for: delay)
        _ = try? await bridge.bashFinished(tag: tag, result: BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false))
      } catch is CancellationError {
        _ = try? await bridge.bashFinished(tag: tag, result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))
      } catch {}
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> CancelResult {
    guard let task = activeTasks.removeValue(forKey: tag) else { return CancelResult(cancelled: false) }
    task.cancel()
    return CancelResult(cancelled: true)
  }

  func waitForBashResult(tag: String) async throws -> BashResult {
    try await bridge.waitForResult(tag: tag)
  }

  func readData(path: String) async throws -> Data { throw RunnerError.fileNotFound(path: path) }
  func readString(path: String, encoding _: String.Encoding) async throws -> String { throw RunnerError.fileNotFound(path: path) }
  func writeData(path _: String, data _: Data, createIntermediateDirectories _: Bool) async throws {}
  func writeString(path _: String, content _: String, createIntermediateDirectories _: Bool, encoding _: String.Encoding) async throws {}
  func exists(path _: String) async throws -> FileExistence { .notFound }
  func listDirectory(path _: String) async throws -> [DirectoryEntry] { [] }
  func enumerateDirectory(root _: String) async throws -> [EnumeratedEntry] { [] }
  func createDirectory(path _: String, withIntermediateDirectories _: Bool) async throws {}
  func find(params _: FindParams) async throws -> FindResult { FindResult(entries: [], totalBeforeLimit: 0) }
  func grep(params _: GrepParams) async throws -> GrepResult { GrepResult(matches: [], matchCount: 0, limitReached: false, linesTruncated: false) }
  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse { MaterializeResponse(workspacePath: params.destinationPath) }
}

// MARK: - MutableFlag

/// Thread-safe flag for testing whether a closure was called.
private final class MutableFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = false
  var value: Bool {
    lock.lock(); defer { lock.unlock() }; return _value
  }

  func set() {
    lock.lock(); _value = true; lock.unlock()
  }
}
