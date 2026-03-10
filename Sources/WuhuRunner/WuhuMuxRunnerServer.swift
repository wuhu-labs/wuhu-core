import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
import MuxSocket
import MuxWebSocket
import WuhuCore
import Yams

/// Configuration for a standalone runner process.
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
  /// Unix domain socket path. When set, the runner listens on a UDS
  /// instead of TCP/WebSocket. Used by the server when spawning a
  /// local runner as a child process.
  public var socket: String?
  /// If true, monitor stdin for EOF and exit when the parent dies.
  /// Set automatically by the server when spawning the local runner.
  public var watchParent: Bool?

  public init(name: String, listen: Listen? = nil, socket: String? = nil, watchParent: Bool? = nil) {
    self.name = name
    self.listen = listen
    self.socket = socket
    self.watchParent = watchParent
  }

  public static func load(path: String) throws -> WuhuRunnerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    return try YAMLDecoder().decode(WuhuRunnerConfig.self, from: text)
  }

  public static func defaultPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/runner.yml")
      .path
  }
}

/// Runs a runner server that accepts connections from a Wuhu server.
///
/// Supports two modes:
/// 1. **WebSocket mode** (default): Listens on HTTP port with WebSocket upgrade.
/// 2. **UDS mode** (`socket` config): Listens on a Unix domain socket via
///    raw mux protocol (no HTTP/WebSocket framing). Used for local runner.
public struct WuhuMuxRunnerServer: Sendable {
  public init() {}

  public func run(configPath: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    let config = try WuhuRunnerConfig.load(path: path)
    try await run(config: config)
  }

  public func run(config: WuhuRunnerConfig) async throws {
    WuhuDebugLogger.bootstrapIfNeeded()

    let logger = Logger(label: "WuhuRunner")
    let name = config.name

    // Start parent watchdog if requested
    if config.watchParent == true {
      startParentWatchdog(logger: logger)
    }

    // Create WorkerManager — all Runner calls are proxied through workers
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
    try await manager.start()
    logger.info("WorkerManager started for runner '\(name)'")

    if let socketPath = config.socket, !socketPath.isEmpty {
      // UDS mode — raw mux over Unix domain socket
      try await runUDS(socketPath: socketPath, runner: manager, name: name, logger: logger)
    } else {
      // WebSocket mode — HTTP server with WS upgrade
      try await runWebSocket(config: config, runner: manager, name: name, logger: logger)
    }
  }

  // MARK: - UDS mode

  private func runUDS(socketPath: String, runner: any Runner, name: String, logger: Logger) async throws {
    logger.info("Starting mux runner '\(name)' on UDS: \(socketPath)")

    let listener = try await SocketListener.bind(unixDomainSocketPath: socketPath)
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

  private func handleMuxConnection(_ connection: SocketConnection, runner: any Runner, name: String, logger: Logger) async {
    let session = MuxSession(connection: connection, role: .responder)

    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await session.run() }
      group.addTask {
        // First stream is hello, then serve RPCs
        await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
        logger.info("Mux UDS connection ended for runner '\(name)'")
      }
    }
  }

  // MARK: - WebSocket mode

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

private func handleWSConnection(
  _ connection: WebSocketConnection,
  runner: any Runner,
  name: String,
  logger: Logger,
) async {
  let session = MuxSession(connection: connection, role: .responder)

  await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await session.run() }
    group.addTask {
      await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
      logger.info("Mux connection from server ended for runner '\(name)'")
    }
  }
}

/// Monitor stdin for EOF. When the server (parent) dies, the pipe closes
/// and this detects it, causing the runner to exit. Works cross-platform.
///
/// NOTE: `exit(0)` bypasses structured concurrency teardown, so in-flight
/// bash processes won't get their `teardownSequence` (SIGTERM → SIGKILL).
/// This is acceptable because the parent dying is an exceptional case —
/// either the server crashed (in which case cleanup is best-effort anyway)
/// or it's shutting down normally (in which case it closes the pipe *after*
/// cancelling in-flight work). Orphaned bash processes will finish naturally.
private func startParentWatchdog(logger: Logger) {
  Task.detached {
    let stdin = FileHandle.standardInput
    // Read blocks until EOF (parent died) or data arrives (shouldn't happen)
    while true {
      let data = stdin.availableData
      if data.isEmpty {
        // EOF — parent is gone
        logger.info("Parent pipe closed — shutting down runner")
        // Give in-flight operations a moment to complete
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
      }
    }
  }
}
