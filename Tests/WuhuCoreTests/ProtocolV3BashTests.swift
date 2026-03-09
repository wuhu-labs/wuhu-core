import Foundation
import Testing
@testable import WuhuCore

/// Tests for the BashTagCoordinator callback routing.
///
/// The coordinator receives bashFinished callbacks from workers and routes
/// them to sessions via the result handler.
@Suite("Bash Callback Routing")
struct BashCallbackRoutingTests {
  @Test("bashFinished routes to handler")
  func bashFinishedRoutesToHandler() async throws {
    let coordinator = BashTagCoordinator()
    let capture = TestResultCapture()

    await coordinator.setResultHandler { tag, result in
      await capture.set(tag: tag, result: result)
    }

    let testResult = BashResult(exitCode: 0, output: "hello\n", timedOut: false, terminated: false)
    try await coordinator.bashFinished(tag: "test-1", result: testResult)

    let (receivedTag, receivedResult) = await capture.get()
    #expect(receivedTag == "test-1")
    #expect(receivedResult?.exitCode == 0)
    #expect(receivedResult?.output == "hello\n")
  }

  @Test("bashFinished without handler logs warning")
  func bashFinishedWithoutHandler() async throws {
    let coordinator = BashTagCoordinator()
    // No handler set — should not crash, just log warning
    let testResult = BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false)
    try await coordinator.bashFinished(tag: "no-handler", result: testResult)
    // If we get here without crash, the test passes
  }

  @Test("Multiple results route independently")
  func multipleResultsRoute() async throws {
    let coordinator = BashTagCoordinator()
    let capture = TestResultListCapture()

    await coordinator.setResultHandler { tag, result in
      await capture.append(tag: tag, result: result)
    }

    try await coordinator.bashFinished(tag: "a", result: BashResult(exitCode: 0, output: "A\n", timedOut: false, terminated: false))
    try await coordinator.bashFinished(tag: "b", result: BashResult(exitCode: 1, output: "B\n", timedOut: false, terminated: false))
    try await coordinator.bashFinished(tag: "c", result: BashResult(exitCode: 2, output: "C\n", timedOut: true, terminated: false))

    let results = await capture.get()
    #expect(results.count == 3)
    #expect(results[0].0 == "a")
    #expect(results[1].0 == "b")
    #expect(results[2].0 == "c")
    #expect(results[2].1.timedOut == true)
  }
}

// MARK: - Test Helpers

private actor TestResultCapture {
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

private actor TestResultListCapture {
  var results: [(String, BashResult)] = []

  func append(tag: String, result: BashResult) {
    results.append((tag, result))
  }

  func get() -> [(String, BashResult)] {
    results
  }
}
