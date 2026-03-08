import Foundation
import Mux
import Testing
@testable import WuhuCore

@Suite("Bash Cancel")
struct BashCancelTests {
  /// Test that cancelling a tagged bash task on the RunnerServerHandler
  /// returns `terminated: true` in the result.
  @Test func cancelTaggedBashViaHandler() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    let tag = "tool-call-123"
    let request = BashRequest(command: "sleep 60", cwd: "/tmp", tag: tag)

    // Start the bash task
    let bashTask = Task {
      await handler.runBash(id: "r1", request: request)
    }
    await handler.registerBashTask(tag, task: bashTask)

    // Give it a moment to start
    try await Task.sleep(for: .milliseconds(50))

    // Cancel via tag
    let found = await handler.cancelBash(tag: tag)
    #expect(found == true)

    // The task should complete with terminated=true
    let (response, _) = await bashTask.value
    guard case let .bash(id, result) = response else {
      Issue.record("Expected bash response"); return
    }
    #expect(id == "r1")
    let r = try result.get()
    #expect(r.terminated == true)
  }

  /// Test that cancelling a non-existent tag returns false.
  @Test func cancelNonExistentTag() async {
    let runner = InMemoryRunner()
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    let found = await handler.cancelBash(tag: "does-not-exist")
    #expect(found == false)
  }

  /// Test cancel via the MuxRunnerOp.cancel RPC through the handler dispatch.
  @Test func cancelViaHandlerDispatch() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    let tag = "tool-call-456"
    let request = BashRequest(command: "sleep 60", cwd: "/tmp", tag: tag)

    // Start the bash task and register it
    let bashTask = Task {
      await handler.runBash(id: "r1", request: request)
    }
    await handler.registerBashTask(tag, task: bashTask)

    try await Task.sleep(for: .milliseconds(50))

    // Send cancel through the handle() dispatch path
    let (response, _) = await handler.handle(request: .cancel(id: "c1", CancelRequest(tag: tag)))
    guard case let .cancel(id, result) = response else {
      Issue.record("Expected cancel response"); return
    }
    #expect(id == "c1")
    let r = try result.get()
    #expect(r.cancelled == true)

    // Bash task should finish with terminated
    let (bashResp, _) = await bashTask.value
    guard case let .bash(_, bashResult) = bashResp else {
      Issue.record("Expected bash response"); return
    }
    let br = try bashResult.get()
    #expect(br.terminated == true)
  }

  /// Test the full cancel flow over mux transport: tagged bash + cancel RPC.
  @Test("Cancel over mux transport", arguments: TransportKind.allCases)
  func cancelOverMux(transport: TransportKind) async throws {
    try await MuxTransportFactory.withPair(transport: transport) { clientSession, serverSession in
      let runner = SlowBashRunner(delay: .seconds(60))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      let tag = "mux-tool-call-789"

      // Start bash with tag in background
      let bashTask = Task {
        try await client.runBash(command: "sleep 60", cwd: "/tmp", timeout: nil, tag: tag)
      }

      // Give the runner time to receive and start processing the bash request
      try await Task.sleep(for: .milliseconds(200))

      // Send cancel
      let cancelResp = try await client.cancel(tag: tag)
      #expect(cancelResp.cancelled == true)

      // Bash task should complete with terminated=true
      let result = try await bashTask.value
      #expect(result.terminated == true)
    }
  }

  /// Test that untagged bash calls are not affected by cancel.
  @Test func untaggedBashNotCancellable() async throws {
    let runner = InMemoryRunner()
    await runner.stubBash(pattern: "echo", result: BashResult(exitCode: 0, output: "ok\n", timedOut: false, terminated: false))
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    // Run untagged bash
    let (response, _) = await handler.handle(request: .bash(id: "r1", BashRequest(command: "echo hi", cwd: "/tmp")))
    guard case let .bash(_, result) = response else {
      Issue.record("Expected bash response"); return
    }
    let r = try result.get()
    #expect(r.exitCode == 0)
    #expect(r.terminated == false)
  }

  /// Test that the BashReaper dispatches cancel to the correct runner.
  @Test func bashReaperDispatchesCancel() async throws {
    try await MuxTransportFactory.withPair(transport: .inMemory) { clientSession, serverSession in
      let runner = SlowBashRunner(delay: .seconds(60))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      // Set up registry with the mux client
      let registry = RunnerRegistry()
      await registry.register(client)

      let reaper = BashReaper(runnerRegistry: registry)

      let tag = "reaper-test-tag"

      // Start bash with tag in background
      let bashTask = Task {
        try await client.runBash(command: "sleep 60", cwd: "/tmp", timeout: nil, tag: tag)
      }

      try await Task.sleep(for: .milliseconds(200))

      // Use the reaper to dispatch cancel
      reaper.enqueueKill(runnerID: .remote(name: "test-runner"), tag: tag)

      // Wait for the bash to complete
      let result = try await bashTask.value
      #expect(result.terminated == true)
    }
  }

  /// Integration test: withTaskCancellationHandler triggers BashReaper.
  @Test func taskCancellationTriggersReaper() async throws {
    try await MuxTransportFactory.withPair(transport: .inMemory) { clientSession, serverSession in
      let runner = SlowBashRunner(delay: .seconds(60))

      let handlerTask = Task {
        await MuxRunnerHandler.serve(session: serverSession, runner: runner, name: "test-runner")
      }
      defer { handlerTask.cancel() }

      let client = MuxRunnerClient(name: "test-runner", session: clientSession)

      let registry = RunnerRegistry()
      await registry.register(client)
      let reaper = BashReaper(runnerRegistry: registry)

      let tag = "integration-cancel-tag"
      let runnerID = client.id

      // Track whether the reaper was called
      let reaperCalled = MutableFlag()

      // Simulate what the bash tool does: run with withTaskCancellationHandler
      let bashTask = Task {
        try await withTaskCancellationHandler {
          try await client.runBash(command: "sleep 60", cwd: "/tmp", timeout: nil, tag: tag)
        } onCancel: {
          reaperCalled.set()
          reaper.enqueueKill(runnerID: runnerID, tag: tag)
        }
      }

      try await Task.sleep(for: .milliseconds(200))

      // Cancel the task (simulates what runtime.stop() does)
      bashTask.cancel()

      // The cancellation handler should fire.
      // The task itself may throw CancellationError (from the mux stream being
      // torn down) or return a terminated result — either is acceptable.
      do {
        let result = try await bashTask.value
        // If we get here, the cancel RPC completed before the stream was torn down
        #expect(result.terminated == true)
      } catch {
        // CancellationError or mux stream error — expected when the task is cancelled
        // while the rpc() is in flight
      }

      // The key assertion: the cancellation handler was invoked
      #expect(reaperCalled.value == true)

      // Give the reaper a moment to dispatch
      try await Task.sleep(for: .milliseconds(200))
    }
  }
}

// MARK: - SlowBashRunner

/// A test runner where bash calls block for a configurable duration.
/// Responds to task cancellation by throwing CancellationError.
private actor SlowBashRunner: Runner {
  nonisolated let id: RunnerID = .local
  let delay: Duration

  init(delay: Duration) {
    self.delay = delay
  }

  func runBash(command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashResult {
    try await Task.sleep(for: delay)
    return BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false)
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
