import Dependencies
import Foundation
import Testing
@testable import WuhuCore

// MARK: - Mock RunnerCallbacks for testing

actor MockRunnerCallbacks: RunnerCallbacks {
  var outputChunks: [(tag: String, chunk: String)] = []
  var finishedResults: [(tag: String, result: BashResult)] = []
  var shouldThrowOnFinished = false

  func bashOutput(tag: String, chunk: String) async throws {
    outputChunks.append((tag: tag, chunk: chunk))
  }

  func bashFinished(tag: String, result: BashResult) async throws {
    if shouldThrowOnFinished {
      throw MockCallbackError.forcedFailure
    }
    finishedResults.append((tag: tag, result: result))
  }

  func setThrowOnFinished(_ value: Bool) {
    shouldThrowOnFinished = value
  }
}

private enum MockCallbackError: Error {
  case forcedFailure
}

// MARK: - Tests

@Suite("WorkerCallbackBuffer")
struct WorkerCallbackBufferTests {
  private let outputDir = "/tmp/test-worker/output"

  private func makeBashResult(exitCode: Int32 = 0, output: String = "ok") -> BashResult {
    BashResult(exitCode: exitCode, output: output, timedOut: false, terminated: false)
  }

  // MARK: - bashFinished with no connection

  @Test func bashFinishedNoConnection_queuesInPending() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let result = makeBashResult(output: "hello")

      try await buffer.bashFinished(tag: "tag-1", result: result)

      let count = await buffer.pendingCount()
      #expect(count == 1)
      #expect(await buffer.allDrained() == false)

      // Verify .result file was written to disk
      let resultData = io.storedData(path: "\(outputDir)/tag-1.result")
      #expect(resultData != nil)
      #expect(!resultData!.isEmpty)

      // Verify it's valid JSON
      let decoded = try JSONDecoder().decode(BashFinished.self, from: resultData!)
      #expect(decoded.tag == "tag-1")
      #expect(decoded.result.output == "hello")
    }
  }

  // MARK: - runnerConnected drains pending

  @Test func runnerConnected_drainsPendingResults() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()

      // Queue some results while disconnected
      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult(output: "r1"))
      try await buffer.bashFinished(tag: "tag-2", result: makeBashResult(output: "r2"))
      #expect(await buffer.pendingCount() == 2)

      // Connect — should drain
      await buffer.runnerConnected(mockCallbacks)

      #expect(await buffer.allDrained() == true)
      #expect(await buffer.pendingCount() == 0)

      // Verify mock received both results
      let finished = await mockCallbacks.finishedResults
      #expect(finished.count == 2)
      #expect(finished[0].tag == "tag-1")
      #expect(finished[1].tag == "tag-2")

      // Verify disk files were cleaned up (overwritten with empty data)
      let r1Data = io.storedData(path: "\(outputDir)/tag-1.result")
      #expect(r1Data != nil)
      #expect(r1Data!.isEmpty)
    }
  }

  // MARK: - bashFinished with live connection

  @Test func bashFinishedWithConnection_forwardsImmediately() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()

      await buffer.runnerConnected(mockCallbacks)
      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult(output: "immediate"))

      // Should not queue — forwarded immediately
      #expect(await buffer.allDrained() == true)
      #expect(await buffer.pendingCount() == 0)

      // Mock should have received it
      let finished = await mockCallbacks.finishedResults
      #expect(finished.count == 1)
      #expect(finished[0].tag == "tag-1")
      #expect(finished[0].result.output == "immediate")
    }
  }

  // MARK: - Disconnect mid-drain

  @Test func disconnectMidDrain_requeuesFailedItems() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()

      // Queue results while disconnected
      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult(output: "r1"))
      try await buffer.bashFinished(tag: "tag-2", result: makeBashResult(output: "r2"))

      // Make mock throw on all calls
      await mockCallbacks.setThrowOnFinished(true)

      // Connect — drain should fail, items re-queued
      await buffer.runnerConnected(mockCallbacks)

      #expect(await buffer.pendingCount() == 2)
      #expect(await buffer.allDrained() == false)
    }
  }

  // MARK: - Forward failure with live connection queues

  @Test func bashFinishedForwardFails_queuesInPending() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()

      await buffer.runnerConnected(mockCallbacks)
      await mockCallbacks.setThrowOnFinished(true)

      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult(output: "fail"))

      // Should be queued since forward failed
      #expect(await buffer.pendingCount() == 1)
    }
  }

  // MARK: - Crash recovery

  @Test func recoverFromDisk_parsesResultFiles() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    // Pre-populate disk with .result files
    let r1 = BashFinished(tag: "recovered-1", result: makeBashResult(output: "from-disk-1"))
    let r2 = BashFinished(tag: "recovered-2", result: makeBashResult(output: "from-disk-2"))
    try io.seedFile(path: "\(outputDir)/recovered-1.result", data: JSONEncoder().encode(r1))
    try io.seedFile(path: "\(outputDir)/recovered-2.result", data: JSONEncoder().encode(r2))
    // Also seed a .out file — should be ignored by recovery
    io.seedFile(path: "\(outputDir)/recovered-1.out", content: "some output")
    // Seed an empty .result file — should be skipped
    io.seedFile(path: "\(outputDir)/empty-tag.result", data: Data())

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)

      await buffer.recoverFromDisk()

      #expect(await buffer.pendingCount() == 2)
      #expect(await buffer.allDrained() == false)
    }
  }

  @Test func recoverFromDisk_skipsDuplicates() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)

      // Add one result to pending via normal path
      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult(output: "in-memory"))

      // Now recover — the tag-1.result file exists on disk (written by bashFinished)
      // but should be skipped since it's already in pending
      await buffer.recoverFromDisk()

      #expect(await buffer.pendingCount() == 1)
    }
  }

  // MARK: - bashOutput chunks

  @Test func bashOutput_appendsToDisk() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)

      try await buffer.bashOutput(tag: "tag-1", chunk: "hello ")
      try await buffer.bashOutput(tag: "tag-1", chunk: "world")

      let stored = io.storedString(path: "\(outputDir)/tag-1.out")
      #expect(stored == "hello world")
    }
  }

  @Test func bashOutput_forwardsToConnection() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()
      await buffer.runnerConnected(mockCallbacks)

      try await buffer.bashOutput(tag: "tag-1", chunk: "data")

      let chunks = await mockCallbacks.outputChunks
      #expect(chunks.count == 1)
      #expect(chunks[0].tag == "tag-1")
      #expect(chunks[0].chunk == "data")
    }
  }

  // MARK: - allDrained

  @Test func allDrained_emptyByDefault() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      #expect(await buffer.allDrained() == true)
    }
  }

  // MARK: - runnerDisconnected

  @Test func runnerDisconnected_nilsOutConnection() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: outputDir)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let buffer = WorkerCallbackBuffer(outputDir: outputDir)
      let mockCallbacks = MockRunnerCallbacks()

      await buffer.runnerConnected(mockCallbacks)
      await buffer.runnerDisconnected()

      // Now bashFinished should queue, not forward
      try await buffer.bashFinished(tag: "tag-1", result: makeBashResult())
      #expect(await buffer.pendingCount() == 1)

      // Mock should not have received it
      let finished = await mockCallbacks.finishedResults
      #expect(finished.isEmpty)
    }
  }
}
