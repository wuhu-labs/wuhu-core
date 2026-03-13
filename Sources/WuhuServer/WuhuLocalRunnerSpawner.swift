import Foundation
import Logging
import Mux
import MuxTCP
import WuhuCore

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

public actor WuhuLocalRunnerSpawner {
  private let socketPath: String
  private let registry: RunnerRegistry
  private let callbacks: any RunnerCallbacks
  private let logger: Logger

  private var childProcess: Process?
  private var connectionTask: Task<Void, Never>?
  private var watchdogPipe: Pipe?
  private var configFilePath: String?

  public init(
    socketPath: String? = nil,
    registry: RunnerRegistry,
    callbacks: any RunnerCallbacks,
    logger: Logger,
  ) {
    self.socketPath = socketPath ?? Self.randomSocketPath()
    self.registry = registry
    self.callbacks = callbacks
    self.logger = logger
  }

  public func start() async throws {
    logger.info("Spawning local runner on UDS: \(socketPath)")

    let configPath = NSTemporaryDirectory() + "wuhu-local-runner-\(UUID().uuidString.lowercased().prefix(8)).yml"
    let configYAML = """
    name: local
    socket: "\(socketPath)"
    watchParent: true
    """
    try configYAML.write(toFile: configPath, atomically: true, encoding: .utf8)
    configFilePath = configPath

    let pipe = Pipe()
    watchdogPipe = pipe

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

    try await waitForSocket(timeout: 10)

    connectionTask = Task { [socketPath, registry, callbacks, logger] in
      var backoff: UInt64 = 100_000_000
      let maxBackoff: UInt64 = 5_000_000_000

      while !Task.isCancelled {
        do {
          let connection = try await TCPConnector.connect(unixDomainSocketPath: socketPath)
          let session = MuxSession(connection: connection, role: .initiator)
          let runTask = Task { try await session.run() }

          let helloStream = try await session.open()
          try await MuxRunnerCodec.writeRequest(
            helloStream,
            op: .hello,
            payload: HelloResponse(runnerName: "wuhu-server", version: muxRunnerProtocolVersion),
          )
          try await helloStream.finish()

          let reader = MuxStreamReader(stream: helloStream)
          let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
          guard ok else {
            let message = String(decoding: Data(payload), as: UTF8.self)
            logger.error("Local runner rejected hello: \(message)")
            await session.close()
            runTask.cancel()
            throw LocalRunnerSpawnError.helloFailed(message)
          }

          let runnerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
          guard runnerHello.version == muxRunnerProtocolVersion else {
            logger.error("Local runner protocol version mismatch: \(runnerHello.version) != \(muxRunnerProtocolVersion)")
            await session.close()
            runTask.cancel()
            throw LocalRunnerSpawnError.versionMismatch(runnerHello.version)
          }

          logger.info("Local runner connected via UDS (v\(runnerHello.version))")

          let client = MuxRunnerClient(id: .local, name: "local", session: session)
          await client.setCallbacks(callbacks)
          let callbackTask = Task { await client.startCallbackListener() }

          await registry.register(client)

          try? await runTask.value
          callbackTask.cancel()
          await session.close()
          await registry.remove(.local)
          logger.info("Local runner UDS connection ended")

          backoff = 100_000_000
        } catch {
          if Task.isCancelled { break }
          logger.error("Local runner connection failed: \(String(describing: error)), reconnecting in \(backoff / 1_000_000)ms")
          try? await Task.sleep(nanoseconds: backoff)
          backoff = min(backoff * 2, maxBackoff)
        }
      }
    }

    try await waitForRegistration(timeout: 10)
    logger.info("Local runner registered and ready")
  }

  public func stop() {
    connectionTask?.cancel()
    connectionTask = nil

    watchdogPipe?.fileHandleForWriting.closeFile()
    watchdogPipe = nil

    if let process = childProcess, process.isRunning {
      process.terminate()
    }
    childProcess = nil

    unlink(socketPath)
    if let configFilePath {
      try? FileManager.default.removeItem(atPath: configFilePath)
      self.configFilePath = nil
    }
  }

  private func waitForSocket(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    throw LocalRunnerSpawnError.socketTimeout(socketPath)
  }

  private func waitForRegistration(timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await registry.get(.local) != nil {
        return
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    throw LocalRunnerSpawnError.registrationTimeout
  }

  private static func randomSocketPath() -> String {
    NSTemporaryDirectory() + "wuhu-local-runner-\(UUID().uuidString.lowercased().prefix(8)).sock"
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
    case let .helloFailed(message):
      "Local runner hello failed: \(message)"
    case let .versionMismatch(version):
      "Local runner protocol version mismatch: \(version)"
    }
  }
}
