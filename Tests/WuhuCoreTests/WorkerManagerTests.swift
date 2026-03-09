import Dependencies
import Foundation
import Testing
@testable import WuhuCore

// MARK: - Mock WorkerSpawner

actor MockWorkerSpawner: WorkerSpawner {
  private(set) var spawnCalls: [(socketPath: String, outputDir: String, orphanDeadline: Int)] = []
  /// FileIO to create socket files on spawn for waitForSocket.
  var mockFileIO: InMemoryFileIO?

  nonisolated func spawn(
    socketPath: String,
    outputDir: String,
    orphanDeadline: Int,
    livenessWriteEnd _: FileHandle,
  ) async throws -> WorkerProcessHandle {
    await recordSpawn(socketPath: socketPath, outputDir: outputDir, orphanDeadline: orphanDeadline)
    return MockProcessHandle()
  }

  private func recordSpawn(socketPath: String, outputDir: String, orphanDeadline: Int) {
    spawnCalls.append((socketPath: socketPath, outputDir: outputDir, orphanDeadline: orphanDeadline))
    mockFileIO?.seedFile(path: socketPath, content: "")
  }
}

final class MockProcessHandle: WorkerProcessHandle, Sendable {
  private nonisolated(unsafe) var _terminated = false

  var isRunning: Bool {
    !_terminated
  }

  func terminate() {
    _terminated = true
  }
}

// MARK: - Mock WorkerConnector for Manager tests

actor MockManagerConnector: WorkerConnector {
  /// Map from socket path to the connection to return.
  var connections: [String: MockManagerConnection] = [:]
  private(set) var connectCalls: [String] = []

  nonisolated func connect(socketPath: String) async throws -> any WorkerConnectionHandle {
    try await doConnect(socketPath: socketPath)
  }

  private func doConnect(socketPath: String) throws -> any WorkerConnectionHandle {
    connectCalls.append(socketPath)
    guard let conn = connections[socketPath] else {
      throw MockManagerConnectorError.connectionRefused
    }
    return conn
  }
}

private enum MockManagerConnectorError: Error {
  case connectionRefused
}

actor MockManagerConnection: WorkerConnectionHandle {
  let runner: any Runner
  private(set) var callbackListenerStarted = false
  private(set) var closed = false
  private var listenerContinuation: CheckedContinuation<Void, Never>?
  var disconnectImmediately = false

  init(runner: any Runner) {
    self.runner = runner
  }

  nonisolated func startCallbackListener() async {
    await doStartCallbackListener()
  }

  private func doStartCallbackListener() async {
    callbackListenerStarted = true
    if disconnectImmediately {
      return
    }
    await withCheckedContinuation { continuation in
      listenerContinuation = continuation
    }
  }

  func simulateDisconnect() {
    let cont = listenerContinuation
    listenerContinuation = nil
    cont?.resume()
  }

  nonisolated func close() async {
    await doClose()
  }

  private func doClose() {
    closed = true
    let cont = listenerContinuation
    listenerContinuation = nil
    cont?.resume()
  }
}

// MARK: - Thread-safe epoch counter

final class AtomicEpochCounter: Sendable {
  private nonisolated(unsafe) var value: Int

  init(start: Int) {
    value = start
  }

  func next() -> Int {
    let v = value
    value += 1
    return v
  }
}

// MARK: - Mock Runner for forwarding tests

actor MockForwardingRunner: Runner {
  nonisolated let id: RunnerID = .local
  private(set) var startBashCalls: [(tag: String, command: String)] = []
  private(set) var cancelBashCalls: [String] = []
  private(set) var callbacksSet: (any RunnerCallbacks)?

  func startBash(tag: String, command: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashStarted {
    startBashCalls.append((tag: tag, command: command))
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  func cancelBash(tag: String) async throws -> BashCancelResult {
    cancelBashCalls.append(tag)
    return .cancelled
  }

  func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    callbacksSet = callbacks
  }

  func readData(path _: String) async throws -> Data {
    Data()
  }

  func readString(path _: String, encoding _: String.Encoding) async throws -> String {
    ""
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

  func materialize(params _: MaterializeRequest) async throws -> MaterializeResponse {
    MaterializeResponse(workspacePath: "")
  }
}

// MARK: - Mock RunnerCallbacks

actor MockUpstreamCallbacks: RunnerCallbacks {
  private(set) var bashOutputCalls: [(tag: String, chunk: String)] = []
  private(set) var bashFinishedCalls: [(tag: String, result: BashResult)] = []

  func bashOutput(tag: String, chunk: String) async throws {
    bashOutputCalls.append((tag: tag, chunk: chunk))
  }

  func bashFinished(tag: String, result: BashResult) async throws {
    bashFinishedCalls.append((tag: tag, result: result))
  }
}

// MARK: - Helper

private func makeManager(
  workersRoot: String,
  io: InMemoryFileIO,
  lockProvider: MockLockProvider,
  spawner: MockWorkerSpawner,
  connector: MockManagerConnector,
  epochCounter: AtomicEpochCounter,
) -> WorkerManager {
  withDependencies {
    $0.fileIO = io
  } operation: {
    WorkerManager(
      runnerName: "test",
      workersRoot: workersRoot,
      lockProvider: lockProvider,
      workerSpawner: spawner,
      workerConnector: connector,
      epochProvider: { epochCounter.next() },
    )
  }
}

// MARK: - Tests

@Suite("WorkerManager")
struct WorkerManagerTests {
  private let workersRoot = "/tmp/test-wm-workers"

  @Test func start_acquiresLockAndSpawnsWorker() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()
    let mockRunner = MockForwardingRunner()
    let mockConn = MockManagerConnection(runner: mockRunner)

    let epochCounter = AtomicEpochCounter(start: 1000)
    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: epochCounter,
    )

    // Pre-register the connection for the socket path that will be spawned
    let expectedSocketPath = "\(workersRoot)/test.worker.1000/socket"
    await connector.setConnection(mockConn, for: expectedSocketPath)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await manager.start()
    }

    // Verify lock was acquired
    #expect(throws: WorkerDiscoveryError.self) {
      _ = try lockProvider.acquireExclusive(path: "\(workersRoot)/test.runner")
    }

    // Verify worker was spawned
    let spawnCalls = await spawner.spawnCalls
    #expect(spawnCalls.count == 1)
    #expect(spawnCalls[0].socketPath == expectedSocketPath)

    // Verify connector was called
    let connectCalls = await connector.connectCalls
    #expect(connectCalls.count == 1)
    #expect(connectCalls[0] == expectedSocketPath)

    await manager.stop()
  }

  @Test func runnerProtocolForwarding() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()
    let mockRunner = MockForwardingRunner()
    let mockConn = MockManagerConnection(runner: mockRunner)

    let epochCounter = AtomicEpochCounter(start: 2000)
    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: epochCounter,
    )

    let expectedSocketPath = "\(workersRoot)/test.worker.2000/socket"
    await connector.setConnection(mockConn, for: expectedSocketPath)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await manager.start()
    }

    // Forward startBash
    let result = try await manager.startBash(tag: "t1", command: "echo hi", cwd: "/", timeout: nil)
    #expect(result.tag == "t1")

    let calls = await mockRunner.startBashCalls
    #expect(calls.count == 1)
    #expect(calls[0].tag == "t1")

    // Forward cancelBash
    let cancelResult = try await manager.cancelBash(tag: "t1")
    #expect(cancelResult == .cancelled)

    let cancelCalls = await mockRunner.cancelBashCalls
    #expect(cancelCalls.count == 1)
    #expect(cancelCalls[0] == "t1")

    await manager.stop()
  }

  @Test func setCallbacksForwardsToWorker() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()
    let mockRunner = MockForwardingRunner()
    let mockConn = MockManagerConnection(runner: mockRunner)

    let epochCounter = AtomicEpochCounter(start: 3000)
    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: epochCounter,
    )

    let expectedSocketPath = "\(workersRoot)/test.worker.3000/socket"
    await connector.setConnection(mockConn, for: expectedSocketPath)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await manager.start()
    }

    // Set callbacks
    let upstream = MockUpstreamCallbacks()
    await manager.setCallbacks(upstream)

    // Verify the runner got a forwarder as callbacks
    let cb = await mockRunner.callbacksSet
    #expect(cb != nil)
    #expect(cb is WorkerCallbackForwarder)

    await manager.stop()
  }

  @Test func previousGenAliveWorkerAdopted() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()

    // Set up a previous-gen worker directory
    let prevDir = "\(workersRoot)/test.worker.500"
    io.seedDirectory(path: workersRoot)
    io.seedDirectory(path: prevDir)
    io.seedFile(path: "\(prevDir)/socket", content: "")
    io.seedDirectory(path: "\(prevDir)/output")

    // Previous-gen worker is alive
    let prevRunner = MockForwardingRunner()
    let prevConn = MockManagerConnection(runner: prevRunner)
    await connector.setConnection(prevConn, for: "\(prevDir)/socket")

    // Current-gen worker
    let currRunner = MockForwardingRunner()
    let currConn = MockManagerConnection(runner: currRunner)

    let epochCounter = AtomicEpochCounter(start: 1000)
    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: epochCounter,
    )

    let expectedCurrentSocket = "\(workersRoot)/test.worker.1000/socket"
    await connector.setConnection(currConn, for: expectedCurrentSocket)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await manager.start()
    }

    // Verify both connections were made
    let connectCalls = await connector.connectCalls
    #expect(connectCalls.count == 2)
    #expect(connectCalls.contains("\(prevDir)/socket"))
    #expect(connectCalls.contains(expectedCurrentSocket))

    // Verify callback listener started on previous-gen
    let started = await prevConn.callbackListenerStarted
    #expect(started)

    await manager.stop()
  }

  @Test func previousGenDeadWorkerScavenged() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()

    // Set up a dead previous-gen worker with results
    let deadDir = "\(workersRoot)/test.worker.400"
    io.seedDirectory(path: workersRoot)
    io.seedDirectory(path: deadDir)
    io.seedFile(path: "\(deadDir)/socket", content: "")
    io.seedDirectory(path: "\(deadDir)/output")
    let finished = BashFinished(
      tag: "dead-t1",
      result: BashResult(exitCode: 0, output: "done", timedOut: false, terminated: false),
    )
    try io.seedFile(path: "\(deadDir)/output/dead-t1.result", data: JSONEncoder().encode(finished))

    // Current-gen worker
    let currRunner = MockForwardingRunner()
    let currConn = MockManagerConnection(runner: currRunner)

    let upstream = MockUpstreamCallbacks()

    let epochCounter = AtomicEpochCounter(start: 1000)
    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: epochCounter,
    )

    let expectedCurrentSocket = "\(workersRoot)/test.worker.1000/socket"
    await connector.setConnection(currConn, for: expectedCurrentSocket)

    // Set callbacks before start so dead worker results get forwarded
    await manager.setCallbacks(upstream)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await manager.start()
    }

    // Verify dead worker results were delivered upstream
    let finishedCalls = await upstream.bashFinishedCalls
    #expect(finishedCalls.count == 1)
    #expect(finishedCalls[0].tag == "dead-t1")
    #expect(finishedCalls[0].result.output == "done")

    await manager.stop()
  }

  @Test func noCurrentWorkerThrows() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    let connector = MockManagerConnector()

    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: AtomicEpochCounter(start: 1),
    )

    // Don't call start() — no worker available
    await #expect(throws: WorkerManagerError.self) {
      _ = try await manager.startBash(tag: "t1", command: "echo", cwd: "/", timeout: nil)
    }
  }

  @Test func lockAlreadyHeldFails() async throws {
    let io = InMemoryFileIO()
    let lockProvider = MockLockProvider()
    let spawner = MockWorkerSpawner()
    await spawner.setMockFileIO(io)
    let connector = MockManagerConnector()

    // Pre-acquire the lock
    let lockPath = "\(workersRoot)/test.runner"
    _ = try lockProvider.acquireExclusive(path: lockPath)

    let manager = makeManager(
      workersRoot: workersRoot, io: io, lockProvider: lockProvider,
      spawner: spawner, connector: connector, epochCounter: AtomicEpochCounter(start: 1),
    )

    await #expect(throws: WorkerDiscoveryError.self) {
      try await withDependencies {
        $0.fileIO = io
      } operation: {
        try await manager.start()
      }
    }
  }
}

// MARK: - WorkerCallbackForwarder tests

@Suite("WorkerCallbackForwarder")
struct WorkerCallbackForwarderTests {
  @Test func forwardsCallbacksUpstream() async throws {
    let upstream = MockUpstreamCallbacks()
    let forwarder = WorkerCallbackForwarder(upstream: upstream)

    try await forwarder.bashOutput(tag: "t1", chunk: "hello")
    try await forwarder.bashFinished(
      tag: "t1",
      result: BashResult(exitCode: 0, output: "hello", timedOut: false, terminated: false),
    )

    let outputs = await upstream.bashOutputCalls
    #expect(outputs.count == 1)
    #expect(outputs[0].tag == "t1")
    #expect(outputs[0].chunk == "hello")

    let finished = await upstream.bashFinishedCalls
    #expect(finished.count == 1)
    #expect(finished[0].tag == "t1")
    #expect(finished[0].result.exitCode == 0)
  }
}

// MARK: - Extensions for test helpers

extension MockWorkerSpawner {
  func setMockFileIO(_ io: InMemoryFileIO) {
    mockFileIO = io
  }
}

extension MockManagerConnector {
  func setConnection(_ conn: MockManagerConnection, for socketPath: String) {
    connections[socketPath] = conn
  }
}
