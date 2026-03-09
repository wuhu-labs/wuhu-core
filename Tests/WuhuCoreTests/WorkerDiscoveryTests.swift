import Foundation
import Testing
@testable import WuhuCore

// MARK: - Mock WorkerConnector

struct MockWorkerConnector: WorkerConnector {
  /// Socket paths that should succeed (return a mock callbacks).
  let liveSocketPaths: Set<String>

  func connect(socketPath: String) async throws -> any RunnerCallbacks {
    if liveSocketPaths.contains(socketPath) {
      return MockDiscoveryCallbacks()
    }
    throw MockConnectorError.connectionRefused
  }
}

private enum MockConnectorError: Error {
  case connectionRefused
}

private actor MockDiscoveryCallbacks: RunnerCallbacks {
  func bashOutput(tag _: String, chunk _: String) async throws {}
  func bashFinished(tag _: String, result _: BashResult) async throws {}
}

// MARK: - Mock LockProvider

final class MockLockProvider: LockProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var heldLocks: Set<String> = []

  func acquireExclusive(path: String) throws -> LockHandle {
    lock.lock()
    defer { lock.unlock() }
    if heldLocks.contains(path) {
      throw WorkerDiscoveryError.lockAlreadyHeld(path: path, errno: 11)
    }
    heldLocks.insert(path)
    return MockLockHandle(path: path, provider: self)
  }

  fileprivate func releaseLock(path: String) {
    lock.lock()
    defer { lock.unlock() }
    heldLocks.remove(path)
  }
}

struct MockLockHandle: LockHandle {
  let path: String
  let provider: MockLockProvider

  func release() {
    provider.releaseLock(path: path)
  }
}

// MARK: - WorkerDirectory naming tests

@Suite("WorkerDirectory")
struct WorkerDirectoryTests {
  @Test func directoryName_formatsCorrectly() {
    let name = WorkerDirectory.directoryName(runnerName: "local", epoch: 1_741_234_567)
    #expect(name == "local.worker.1741234567")
  }

  @Test func parse_validName() {
    let result = WorkerDirectory.parse(directoryName: "local.worker.1741234567")
    #expect(result?.runnerName == "local")
    #expect(result?.epoch == 1_741_234_567)
  }

  @Test func parse_nameWithDots() {
    let result = WorkerDirectory.parse(directoryName: "my.runner.worker.12345")
    #expect(result?.runnerName == "my.runner")
    #expect(result?.epoch == 12345)
  }

  @Test func parse_invalidName_noWorkerSegment() {
    let result = WorkerDirectory.parse(directoryName: "local.1741234567")
    #expect(result == nil)
  }

  @Test func parse_invalidName_nonNumericEpoch() {
    let result = WorkerDirectory.parse(directoryName: "local.worker.abc")
    #expect(result == nil)
  }

  @Test func parse_invalidName_emptyName() {
    let result = WorkerDirectory.parse(directoryName: ".worker.123")
    #expect(result == nil)
  }

  @Test func sortedByEpoch_sortsAscending() {
    let dirs = [
      "local.worker.300",
      "local.worker.100",
      "local.worker.200",
    ]
    let sorted = WorkerDirectory.sortedByEpoch(dirs)
    #expect(sorted == ["local.worker.100", "local.worker.200", "local.worker.300"])
  }

  @Test func workerPath_buildsCorrectPath() {
    let path = WorkerDirectory.workerPath(workersRoot: "/home/user/.wuhu/workers", runnerName: "local", epoch: 123)
    #expect(path == "/home/user/.wuhu/workers/local.worker.123")
  }

  @Test func socketPath_buildsCorrectPath() {
    let path = WorkerDirectory.socketPath(workerDir: "/home/user/.wuhu/workers/local.worker.123")
    #expect(path == "/home/user/.wuhu/workers/local.worker.123/socket")
  }

  @Test func outputPath_buildsCorrectPath() {
    let path = WorkerDirectory.outputPath(workerDir: "/home/user/.wuhu/workers/local.worker.123")
    #expect(path == "/home/user/.wuhu/workers/local.worker.123/output")
  }
}

// MARK: - Worker discovery tests

@Suite("Worker Discovery")
struct WorkerDiscoveryFunctionTests {
  private let workersRoot = "/tmp/test-workers"

  private func makeBashResult(output: String = "ok") -> BashResult {
    BashResult(exitCode: 0, output: output, timedOut: false, terminated: false)
  }

  @Test func discoverWorkers_findsLiveAndDeadWorkers() async throws {
    let io = InMemoryFileIO()

    // Set up two worker directories
    let liveDir = "\(workersRoot)/local.worker.100"
    let deadDir = "\(workersRoot)/local.worker.200"
    io.seedDirectory(path: workersRoot)
    io.seedDirectory(path: liveDir)
    io.seedDirectory(path: deadDir)

    // Live worker has a socket
    io.seedFile(path: "\(liveDir)/socket", content: "")
    io.seedDirectory(path: "\(liveDir)/output")

    // Dead worker has results on disk
    io.seedFile(path: "\(deadDir)/socket", content: "")
    io.seedDirectory(path: "\(deadDir)/output")
    let finished = BashFinished(tag: "dead-tag", result: makeBashResult(output: "dead-result"))
    try io.seedFile(path: "\(deadDir)/output/dead-tag.result", data: JSONEncoder().encode(finished))

    let connector = MockWorkerConnector(liveSocketPaths: ["\(liveDir)/socket"])
    let results = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: "local",
      fileIO: io,
      connector: connector,
    )

    #expect(results.count == 2)

    // First (epoch 100) should be alive
    #expect(results[0].directory == "local.worker.100")
    if case .alive = results[0].result {} else {
      Issue.record("Expected alive for worker 100")
    }

    // Second (epoch 200) should be dead with results
    #expect(results[1].directory == "local.worker.200")
    if case let .dead(deadResults) = results[1].result {
      #expect(deadResults.count == 1)
      #expect(deadResults[0].tag == "dead-tag")
      #expect(deadResults[0].result.output == "dead-result")
    } else {
      Issue.record("Expected dead for worker 200")
    }
  }

  @Test func discoverWorkers_sortsbyEpoch() async {
    let io = InMemoryFileIO()
    io.seedDirectory(path: workersRoot)
    io.seedDirectory(path: "\(workersRoot)/local.worker.300")
    io.seedDirectory(path: "\(workersRoot)/local.worker.100")
    io.seedDirectory(path: "\(workersRoot)/local.worker.200")
    io.seedFile(path: "\(workersRoot)/local.worker.300/socket", content: "")
    io.seedFile(path: "\(workersRoot)/local.worker.100/socket", content: "")
    io.seedFile(path: "\(workersRoot)/local.worker.200/socket", content: "")
    io.seedDirectory(path: "\(workersRoot)/local.worker.300/output")
    io.seedDirectory(path: "\(workersRoot)/local.worker.100/output")
    io.seedDirectory(path: "\(workersRoot)/local.worker.200/output")

    let connector = MockWorkerConnector(liveSocketPaths: [])
    let results = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: "local",
      fileIO: io,
      connector: connector,
    )

    #expect(results.count == 3)
    #expect(results[0].directory == "local.worker.100")
    #expect(results[1].directory == "local.worker.200")
    #expect(results[2].directory == "local.worker.300")
  }

  @Test func discoverWorkers_filtersbyRunnerName() async {
    let io = InMemoryFileIO()
    io.seedDirectory(path: workersRoot)
    io.seedDirectory(path: "\(workersRoot)/local.worker.100")
    io.seedDirectory(path: "\(workersRoot)/other.worker.200")
    io.seedFile(path: "\(workersRoot)/local.worker.100/socket", content: "")
    io.seedFile(path: "\(workersRoot)/other.worker.200/socket", content: "")
    io.seedDirectory(path: "\(workersRoot)/local.worker.100/output")
    io.seedDirectory(path: "\(workersRoot)/other.worker.200/output")

    let connector = MockWorkerConnector(liveSocketPaths: [])
    let results = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: "local",
      fileIO: io,
      connector: connector,
    )

    #expect(results.count == 1)
    #expect(results[0].directory == "local.worker.100")
  }

  @Test func discoverWorkers_emptyDirectory() async {
    let io = InMemoryFileIO()
    io.seedDirectory(path: workersRoot)

    let connector = MockWorkerConnector(liveSocketPaths: [])
    let results = await discoverWorkers(
      workersRoot: workersRoot,
      runnerName: "local",
      fileIO: io,
      connector: connector,
    )

    #expect(results.isEmpty)
  }

  @Test func parseResultFiles_parsesValidFiles() throws {
    let io = InMemoryFileIO()
    let outputDir = "\(workersRoot)/output"
    io.seedDirectory(path: outputDir)

    let r1 = BashFinished(tag: "t1", result: makeBashResult(output: "out1"))
    let r2 = BashFinished(tag: "t2", result: makeBashResult(output: "out2"))
    try io.seedFile(path: "\(outputDir)/t1.result", data: JSONEncoder().encode(r1))
    try io.seedFile(path: "\(outputDir)/t2.result", data: JSONEncoder().encode(r2))
    io.seedFile(path: "\(outputDir)/t1.out", content: "output chunks")
    io.seedFile(path: "\(outputDir)/empty.result", data: Data())

    let results = parseResultFiles(outputDir: outputDir, fileIO: io)

    #expect(results.count == 2)
    let tags = Set(results.map(\.tag))
    #expect(tags.contains("t1"))
    #expect(tags.contains("t2"))
  }
}

// MARK: - LockProvider tests

@Suite("LockProvider")
struct LockProviderTests {
  @Test func mockLockProvider_acquireAndRelease() throws {
    let provider = MockLockProvider()

    let handle = try provider.acquireExclusive(path: "/tmp/test.lock")
    // Second acquire should fail
    #expect(throws: WorkerDiscoveryError.self) {
      _ = try provider.acquireExclusive(path: "/tmp/test.lock")
    }

    // Release and re-acquire should work
    handle.release()
    let handle2 = try provider.acquireExclusive(path: "/tmp/test.lock")
    handle2.release()
  }

  @Test func mockLockProvider_differentPaths() throws {
    let provider = MockLockProvider()

    let h1 = try provider.acquireExclusive(path: "/tmp/a.lock")
    let h2 = try provider.acquireExclusive(path: "/tmp/b.lock")

    h1.release()
    h2.release()
  }
}
