import Foundation
import Logging
import Mux
import MuxSocket
import WuhuCore

/// Manages the local runner as a child process of the server.
///
/// On startup, the server:
/// 1. Picks a UDS socket path (from config or a random temp path)
/// 2. Writes a temporary runner config file
/// 3. Spawns `wuhu runner --config <tmpfile>` as a child process
/// 4. Connects to the runner over UDS mux
/// 5. Registers it as "local" in the runner registry
///
/// The runner monitors stdin for EOF — the server keeps the write end of a
/// pipe open as stdin. When the server dies (for any reason), the pipe closes,
/// the runner detects EOF and exits. This works cross-platform.
public actor WuhuLocalRunnerSpawner {
  private let socketPath: String
  private let registry: RunnerRegistry
  private let bashCoordinator: BashTagCoordinator
  private let logger: Logger
  private var childProcess: Process?
  private var connectionTask: Task<Void, Never>?
  private var watchdogPipe: Pipe?
  private var configFilePath: String?

  public init(
    socketPath: String? = nil,
    registry: RunnerRegistry,
    bashCoordinator: BashTagCoordinator,
    logger: Logger,
  ) {
    self.socketPath = socketPath ?? WuhuLocalRunnerSpawner.randomSocketPath()
    self.registry = registry
    self.bashCoordinator = bashCoordinator
    self.logger = logger
  }

  /// Spawn the local runner and connect to it. Returns when connected.
  public func start() async throws {
    logger.info("Spawning local runner on UDS: \(socketPath)")

    // Write temporary runner config
    let configPath = NSTemporaryDirectory() + "wuhu-local-runner-\(UUID().uuidString.lowercased().prefix(8)).yml"
    let configYAML = """
    name: local
    socket: "\(socketPath)"
    watchParent: true
    """
    try configYAML.write(toFile: configPath, atomically: true, encoding: .utf8)
    configFilePath = configPath

    // Create the watchdog pipe — server holds the write end, runner gets the read end as stdin
    let pipe = Pipe()
    watchdogPipe = pipe

    // Spawn the runner child process.
    //
    // NOTE: We use Foundation.Process here rather than swift-subprocess because
    // the runner is a long-lived child process (not a short-lived command).
    // The Linux Foundation.Process bugs (isRunning TOCTOU races, terminationStatus
    // SIGILL) primarily affect short-lived processes where you poll for completion.
    // For this spawner, the child runs for the server's entire lifetime, and we
    // only call terminate() during an orderly shutdown where the race is benign.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    process.arguments = ["runner", "--config", configPath]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.standardInput = pipe.fileHandleForReading
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError

    try process.run()
    childProcess = process
    logger.info("Local runner spawned (pid=\(process.processIdentifier))")

    // Wait for the socket to appear, then connect
    try await waitForSocket(timeout: 10.0)

    // Connect to the local runner over UDS mux with reconnection
    connectionTask = Task { [socketPath, registry, bashCoordinator, logger] in
      var backoff: UInt64 = 100_000_000 // 100ms
      let maxBackoff: UInt64 = 5_000_000_000

      while !Task.isCancelled {
        do {
          let connection = try await SocketConnector.connect(unixDomainSocketPath: socketPath)
          let session = MuxSession(connection: connection, role: .initiator)
          let runTask = Task { try await session.run() }

          // Hello exchange
          let helloStream = try await session.open()
          let hello = HelloResponse(runnerName: "wuhu-server", version: muxRunnerProtocolVersion)
          try await MuxRunnerCodec.writeRequest(helloStream, op: .hello, payload: hello)
          try await helloStream.finish()

          let reader = MuxStreamReader(stream: helloStream)
          let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
          guard ok else {
            let msg = String(decoding: Data(payload), as: UTF8.self)
            logger.error("Local runner rejected hello: \(msg)")
            await session.close()
            runTask.cancel()
            throw LocalRunnerSpawnError.helloFailed(msg)
          }
          let runnerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
          guard runnerHello.version == muxRunnerProtocolVersion else {
            logger.error("Local runner protocol version mismatch: \(runnerHello.version) != \(muxRunnerProtocolVersion)")
            await session.close()
            runTask.cancel()
            throw LocalRunnerSpawnError.versionMismatch(runnerHello.version)
          }

          logger.info("Local runner connected via UDS (v\(runnerHello.version))")

          let client = MuxRunnerClient(name: "local", session: session)

          // Wire callbacks: inbound callback streams → bashCoordinator
          await client.setCallbacks(bashCoordinator)
          let callbackTask = Task { await client.startCallbackListener() }

          await registry.register(client)

          // Block until session ends
          try? await runTask.value
          callbackTask.cancel()
          await session.close()

          await registry.remove(.remote(name: "local"))
          logger.info("Local runner UDS connection ended")

          backoff = 100_000_000
        } catch {
          if Task.isCancelled { break }
          logger.error("Local runner connection failed: \(error), reconnecting in \(backoff / 1_000_000)ms")
          try? await Task.sleep(nanoseconds: backoff)
          backoff = min(backoff * 2, maxBackoff)
        }
      }
    }

    // Wait until the local runner is actually registered
    try await waitForRegistration(timeout: 10.0)
    logger.info("Local runner registered and ready")
  }

  /// Stop the local runner child process.
  ///
  /// There is a small race between cancelling `connectionTask` and unlinking the
  /// socket — the reconnection logic might briefly try to reconnect to a deleted
  /// socket. This is benign: the reconnection will fail and the task checks
  /// `Task.isCancelled`.
  public func stop() {
    connectionTask?.cancel()
    connectionTask = nil

    // Close the watchdog pipe — this causes the runner to detect EOF and exit
    watchdogPipe?.fileHandleForWriting.closeFile()
    watchdogPipe = nil

    if let process = childProcess, process.isRunning {
      process.terminate()
    }
    childProcess = nil

    // Clean up socket file and config
    unlink(socketPath)
    if let configPath = configFilePath {
      try? FileManager.default.removeItem(atPath: configPath)
      configFilePath = nil
    }
  }

  // MARK: - Private helpers

  private func waitForSocket(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
    throw LocalRunnerSpawnError.socketTimeout(socketPath)
  }

  private func waitForRegistration(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await registry.get(.local) != nil {
        return
      }
      try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    }
    throw LocalRunnerSpawnError.registrationTimeout
  }

  private static func randomSocketPath() -> String {
    let dir = NSTemporaryDirectory()
    return "\(dir)wuhu-local-runner-\(UUID().uuidString.lowercased().prefix(8)).sock"
  }
}

enum LocalRunnerSpawnError: Error, CustomStringConvertible {
  case socketTimeout(String)
  case registrationTimeout
  case helloFailed(String)
  case versionMismatch(Int)

  var description: String {
    switch self {
    case let .socketTimeout(path):
      "Local runner socket did not appear at \(path) within timeout"
    case .registrationTimeout:
      "Local runner did not register within timeout"
    case let .helloFailed(msg):
      "Local runner hello failed: \(msg)"
    case let .versionMismatch(v):
      "Local runner protocol version mismatch: \(v)"
    }
  }
}
