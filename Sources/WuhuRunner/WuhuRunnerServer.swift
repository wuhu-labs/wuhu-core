import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
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

/// Runs a standalone runner server that accepts WebSocket connections from a Wuhu server.
public struct WuhuRunnerServer: Sendable {
  public init() {}

  public func run(configPath: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    let config = try WuhuRunnerConfig.load(path: path)

    let runner = LocalRunner()
    let handler = RunnerServerHandler(runner: runner, name: config.name)

    let host = config.listen?.host ?? "0.0.0.0"
    let port = config.listen?.port ?? 5531

    let logger = Logger(label: "WuhuRunner")
    logger.info("Starting runner '\(config.name)' on \(host):\(port)")

    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.ws("/v1/runner/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, _ in
      // Send hello
      let hello = RunnerResponse.hello(runnerName: config.name, version: runnerProtocolVersion)
      let helloData = try JSONEncoder().encode(hello)
      try await outbound.write(.text(String(decoding: helloData, as: UTF8.self)))

      // Process incoming requests
      for try await message in inbound.messages(maxSize: 64 * 1024 * 1024) {
        guard case let .text(text) = message else { continue }
        guard let data = text.data(using: .utf8) else { continue }

        do {
          let request = try JSONDecoder().decode(RunnerRequest.self, from: data)
          let response = await handler.handle(request: request)
          let responseData = try JSONEncoder().encode(response)
          try await outbound.write(.text(String(decoding: responseData, as: UTF8.self)))
        } catch {
          logger.error("Failed to process runner request: \(error)")
        }
      }
    }

    let app = Application(
      router: Router(),
      server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
      configuration: .init(address: .hostname(host, port: port)),
      logger: logger,
    )
    try await app.runService()
  }
}
