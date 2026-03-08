import Foundation
import Mux
import Testing
@testable import WuhuCore

@Suite("Bash Cancel")
struct BashCancelTests {
  /// Test that cancelBash on the handler dispatches to the runner.
  @Test func cancelBashViaHandler() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    let tag = "tool-call-123"
    let req = StartBashRequest(tag: tag, command: "sleep 60", cwd: "/tmp")

    // Start bash
    let (response, _) = await handler.handle(request: .startBash(id: "r1", req))
    guard case let .startBash(_, result) = response else {
      Issue.record("Expected startBash response"); return
    }
    let started = try result.get()
    #expect(started.alreadyRunning == false)

    // Cancel it
    let (cancelResp, _) = await handler.handle(request: .cancelBash(id: "c1", CancelBashRequest(tag: tag)))
    guard case let .cancelBash(_, cancelResult) = cancelResp else {
      Issue.record("Expected cancelBash response"); return
    }
    let cr = try cancelResult.get()
    #expect(cr == .cancelled)
  }

  /// Test that cancelling a non-existent tag returns notFound.
  @Test func cancelNonExistentTag() async throws {
    let runner = InMemoryRunner()
    let handler = RunnerServerHandler(runner: runner, name: "test-runner")

    let (response, _) = await handler.handle(request: .cancelBash(id: "c1", CancelBashRequest(tag: "does-not-exist")))
    guard case let .cancelBash(_, result) = response else {
      Issue.record("Expected cancelBash response"); return
    }
    let cr = try result.get()
    #expect(cr == .notFound)
  }

  /// Test cancel over mux transport.
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

      // Start bash
      let started = try await client.startBash(tag: tag, command: "sleep 60", cwd: "/tmp", timeout: nil)
      #expect(started.alreadyRunning == false)

      // Cancel it
      let result = try await client.cancelBash(tag: tag)
      #expect(result == .cancelled)

      // Cancel again — notFound
      let result2 = try await client.cancelBash(tag: tag)
      #expect(result2 == .notFound)
    }
  }

  /// Test BashTagCoordinator cancel flow: start → cancel → result is terminated.
  @Test func coordinatorCancelBeforeResult() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let tag = "coord-cancel-1"

    // Start runBash in background — it will wait for bashFinished
    let bashTask = Task {
      try await coordinator.runBash(
        tag: tag,
        command: "sleep 60",
        runner: runner,
        cwd: "/tmp",
        timeout: nil,
      )
    }

    // Give it time to enter the continuation
    try await Task.sleep(for: .milliseconds(50))

    // Cancel via coordinator
    await coordinator.cancel(tag: tag, runner: runner)

    // Should return terminated
    let result = try await bashTask.value
    #expect(result.terminated == true)
    #expect(result.exitCode == -15)
  }

  /// Test BashTagCoordinator pre-cancel: cancel before start.
  @Test func coordinatorPreCancel() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let tag = "pre-cancel-1"

    // Cancel before start
    await coordinator.cancel(tag: tag, runner: runner)

    // Now start — should return terminated immediately
    let result = try await coordinator.runBash(
      tag: tag,
      command: "sleep 60",
      runner: runner,
      cwd: "/tmp",
      timeout: nil,
    )
    #expect(result.terminated == true)
    #expect(result.exitCode == -15)
  }
}

// MARK: - SlowBashRunner

/// A test runner where bash processes block for a configurable duration.
/// Uses v3 protocol: startBash spawns a delayed task, cancelBash cancels it.
private actor SlowBashRunner: Runner {
  nonisolated let id: RunnerID = .local
  let delay: Duration
  private var activeTasks: [String: Task<Void, Never>] = [:]
  private var callbacks: (any RunnerCallbacks)?

  init(delay: Duration) {
    self.delay = delay
  }

  func setCallbacks(_ cb: any RunnerCallbacks) async {
    callbacks = cb
  }

  func startBash(tag: String, command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    if activeTasks[tag] != nil {
      return BashStarted(tag: tag, alreadyRunning: true)
    }
    let cb = callbacks
    let d = delay
    let task = Task { [weak self] in
      do {
        try await Task.sleep(for: d)
        try? await cb?.bashFinished(tag: tag, result: BashResult(exitCode: 0, output: "done\n", timedOut: false, terminated: false))
      } catch {
        try? await cb?.bashFinished(tag: tag, result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))
      }
      await self?.unregister(tag: tag)
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> BashCancelResult {
    guard let task = activeTasks.removeValue(forKey: tag) else {
      return .notFound
    }
    task.cancel()
    return .cancelled
  }

  private func unregister(tag: String) {
    activeTasks.removeValue(forKey: tag)
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
