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

  /// Test that coordinator routes bashFinished from runner to handler.
  @Test func coordinatorRoutesBashFinished() async throws {
    let runner = SlowBashRunner(delay: .milliseconds(10))
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let capture = ResultCapture()
    await coordinator.setResultHandler { tag, result in
      await capture.set(tag: tag, result: result)
    }

    // Start bash — it will complete after 10ms delay
    _ = try await runner.startBash(tag: "coord-1", command: "echo", cwd: "/tmp", timeout: nil)

    // Wait for the delayed completion
    try await Task.sleep(for: .seconds(1))

    let (receivedTag, receivedResult) = await capture.get()
    #expect(receivedTag == "coord-1")
    #expect(receivedResult?.exitCode == 0)
  }

  /// Test that cancelled bash delivers terminated result to coordinator.
  @Test func coordinatorReceivesCancelledResult() async throws {
    let runner = SlowBashRunner(delay: .seconds(60))
    let coordinator = BashTagCoordinator()
    await runner.setCallbacks(coordinator)

    let capture = ResultCapture()
    await coordinator.setResultHandler { tag, result in
      await capture.set(tag: tag, result: result)
    }

    // Start bash
    _ = try await runner.startBash(tag: "cancel-1", command: "sleep 60", cwd: "/tmp", timeout: nil)

    // Cancel it
    _ = try await runner.cancelBash(tag: "cancel-1")

    // Wait for the cancellation result to be delivered
    try await Task.sleep(for: .seconds(1))

    let (receivedTag, receivedResult) = await capture.get()
    #expect(receivedTag == "cancel-1")
    #expect(receivedResult?.terminated == true)
    #expect(receivedResult?.exitCode == -15)
  }
}

// MARK: - ResultCapture

private actor ResultCapture {
  var tag: String?
  var result: BashResult?

  func set(tag: String, result: BashResult) {
    self.tag = tag
    self.result = result
  }

  func get() -> (String?, BashResult?) {
    (tag, result)
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
