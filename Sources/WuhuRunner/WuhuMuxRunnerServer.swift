import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
import MuxTCP
import MuxWebSocket
import WuhuCore
import Yams

public struct WuhuRunnerConfig: Sendable, Hashable, Codable {
  public struct Listen: Sendable, Hashable, Codable {
    public var host: String?
    public var port: Int?

    public init(host: String? = nil, port: Int? = nil) {
      self.host = host
      self.port = port
    }
  }

  public var name: String
  public var listen: Listen?
  public var socket: String?
  public var watchParent: Bool?

  public init(name: String, listen: Listen? = nil, socket: String? = nil, watchParent: Bool? = nil) {
    self.name = name
    self.listen = listen
    self.socket = socket
    self.watchParent = watchParent
  }

  public static func load(path: String) throws -> WuhuRunnerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    return try YAMLDecoder().decode(WuhuRunnerConfig.self, from: String(contentsOfFile: expanded, encoding: .utf8))
  }

  public static func defaultPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/runner.yml")
      .path
  }
}

public struct WuhuMuxRunnerServer: Sendable {
  public init() {}

  public func run(configPath: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    try await run(config: WuhuRunnerConfig.load(path: path))
  }

  public func run(config: WuhuRunnerConfig) async throws {
    let logger = Logger(label: "WuhuRunner")
    let name = config.name

    if config.watchParent == true {
      startParentWatchdog(logger: logger)
    }

    let workersRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/workers")
      .path
    let manager = WorkerManager(
      runnerName: name,
      workersRoot: workersRoot,
      lockProvider: FlockLockProvider(),
      workerSpawner: RealWorkerSpawner(),
      workerConnector: MuxWorkerConnector(),
    )
    defer { Task { await manager.stop() } }
    try await manager.start()
    logger.info("WorkerManager started for runner '\(name)'")

    if let socketPath = config.socket, !socketPath.isEmpty {
      try await runUDS(socketPath: socketPath, runner: manager, name: name, logger: logger)
    } else {
      try await runWebSocket(config: config, runner: manager, name: name, logger: logger)
    }
  }

  private func runUDS(socketPath: String, runner: any Runner, name: String, logger: Logger) async throws {
    logger.info("Starting mux runner '\(name)' on UDS: \(socketPath)")
    let listener = try await TCPListener.bind(unixDomainSocketPath: socketPath)
    logger.info("Runner '\(name)' listening on \(socketPath)")

    for await connection in listener.connections {
      let runner = runner
      let name = name
      let logger = logger
      Task {
        await handleMuxConnection(connection, runner: runner, name: name, logger: logger)
      }
    }
  }

  private func runWebSocket(config: WuhuRunnerConfig, runner: any Runner, name: String, logger: Logger) async throws {
    let host = config.listen?.host ?? "0.0.0.0"
    let port = config.listen?.port ?? 5532
    logger.info("Starting mux runner '\(name)' on \(host):\(port)")

    let httpRouter = Router()
    httpRouter.get("healthz") { _, _ -> String in "ok" }

    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.ws("v1/runner/mux") { _, _ in
      .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
      let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
      await handleWSConnection(conn, runner: runner, name: name, logger: logger)
    }

    let app = Application(
      router: httpRouter,
      server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
      configuration: .init(address: .hostname(host, port: port)),
      logger: logger,
    )
    try await app.runService()
  }
}

private func handleMuxConnection(_ connection: TCPConnection, runner: any Runner, name: String, logger: Logger) async {
  let session = MuxSession(connection: connection, role: .responder)
  await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await session.run() }
    group.addTask {
      await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
      logger.info("Mux UDS connection ended for runner '\(name)'")
    }
  }
}

private func handleWSConnection(_ connection: WebSocketConnection, runner: any Runner, name: String, logger: Logger) async {
  let session = MuxSession(connection: connection, role: .responder)
  await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await session.run() }
    group.addTask {
      await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
      logger.info("Mux connection from server ended for runner '\(name)'")
    }
  }
}

private func startParentWatchdog(logger: Logger) {
  Task.detached {
    let stdin = FileHandle.standardInput
    while true {
      let data = stdin.availableData
      if data.isEmpty {
        logger.info("Parent pipe closed — shutting down runner")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
      }
    }
  }
}
