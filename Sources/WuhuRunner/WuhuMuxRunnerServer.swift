import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
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

  public init(name: String, listen: Listen? = nil) {
    self.name = name
    self.listen = listen
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

/// Runs a WebSocket-based runner server that accepts connections from a Wuhu server.
///
/// The runner listens on an HTTP port with a WebSocket upgrade route at
/// `/v1/runner/mux`. When a server connects and upgrades, the runner
/// performs a hello exchange and then serves RPC requests over mux streams.
public struct WuhuMuxRunnerServer: Sendable {
  public init() {}

  public func run(configPath: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    let config = try WuhuRunnerConfig.load(path: path)
    try await run(config: config)
  }

  public func run(config: WuhuRunnerConfig) async throws {
    let runner = LocalRunner()
    let host = config.listen?.host ?? "0.0.0.0"
    let port = config.listen?.port ?? 5532

    let logger = Logger(label: "WuhuRunner")
    logger.info("Starting mux runner '\(config.name)' on \(host):\(port)")

    let name = config.name

    let httpRouter = Router()
    httpRouter.get("healthz") { _, _ -> String in "ok" }

    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.ws("v1/runner/mux") { _, _ in
      .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
      let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
      await handleConnection(conn, runner: runner, name: name, logger: logger)
    }

    let app = Application(
      router: httpRouter,
      server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
      configuration: .init(address: .hostname(host, port: port)),
      logger: logger
    )
    try await app.runService()
  }
}

private func handleConnection(
  _ connection: WebSocketConnection,
  runner: any Runner,
  name: String,
  logger: Logger
) async {
  let session = MuxSession(connection: connection, role: .responder)

  await withTaskGroup(of: Void.self) { group in
    group.addTask { try? await session.run() }
    group.addTask {
      // Serve all RPC requests — hello is handled as the first stream
      await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
      logger.info("Mux connection from server ended for runner '\(name)'")
    }
  }
}
