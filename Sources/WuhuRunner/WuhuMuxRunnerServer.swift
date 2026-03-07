import Foundation
import Logging
import Mux
import MuxTCP
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

/// Runs a mux-based runner server that accepts TCP connections from a Wuhu server.
///
/// This is the runner-side counterpart to `WuhuMuxRunnerConnector`.
/// The runner listens on a TCP port, accepts mux sessions, performs hello
/// exchange, and then serves RPC requests.
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

    let listener = try await TCPListener.bind(host: host, port: port)

    for await connection in listener.connections {
      let runner = runner
      let name = config.name
      let logger = logger
      Task {
        await handleConnection(connection, runner: runner, name: name, logger: logger)
      }
    }
  }

  private func handleConnection(
    _ connection: TCPConnection,
    runner: any Runner,
    name: String,
    logger: Logger,
  ) async {
    let session = MuxSession(connection: connection, role: .responder)

    await withTaskGroup(of: Void.self) { group in
      group.addTask { try? await session.run() }
      group.addTask {
        // Wait for the first inbound stream (hello)
        do {
          let hello = try await MuxRunnerHello.receiveFromRunner(session: session, serverName: name)
          _ = hello
          logger.info("Mux server connected to runner '\(name)'")
        } catch {
          logger.error("Hello exchange failed: \(error)")
          await session.close()
          return
        }

        // Serve RPC requests
        await MuxRunnerHandler.serve(session: session, runner: runner, name: name)
      }
    }
  }
}
