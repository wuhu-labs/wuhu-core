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

    /// Track pending binary writes: id → (path, createDirs)
    actor PendingBinaryWrites {
      var writes: [String: (path: String, createDirs: Bool)] = [:]
      func set(_ id: String, path: String, createDirs: Bool) { writes[id] = (path, createDirs) }
      func remove(_ id: String) -> (path: String, createDirs: Bool)? { writes.removeValue(forKey: id) }
    }

    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    wsRouter.ws("/v1/runner/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, _ in
      let pendingWrites = PendingBinaryWrites()

      // Send hello
      let hello = RunnerResponse.hello(HelloResponse(runnerName: config.name, version: runnerProtocolVersion))
      let helloData = try JSONEncoder().encode(hello)
      try await outbound.write(.text(String(decoding: helloData, as: UTF8.self)))

      // Process incoming messages
      for try await message in inbound.messages(maxSize: 256 * 1024 * 1024) {
        switch message {
        case let .text(text):
          guard let data = text.data(using: .utf8) else { continue }
          do {
            let request = try JSONDecoder().decode(RunnerRequest.self, from: data)

            // If this is a binary write (content is nil), stash the write info and wait for binary frame
            if case let .write(id, p) = request, p.content == nil {
              await pendingWrites.set(id, path: p.path, createDirs: p.createDirs)
              continue
            }

            let (response, binaryData) = await handler.handle(request: request)
            let responseData = try JSONEncoder().encode(response)
            try await outbound.write(.text(String(decoding: responseData, as: UTF8.self)))

            // Send companion binary frame if present (e.g., binary read response)
            if let binaryData, let id = response.responseID {
              let frame = RunnerBinaryFrame.encode(id: id, data: binaryData)
              try await outbound.write(.binary(ByteBuffer(data: frame)))
            }
          } catch {
            logger.error("Failed to process runner request: \(error)")
          }

        case let .binary(buffer):
          let frameData = Data(buffer: buffer)
          guard let (id, payload) = RunnerBinaryFrame.decode(frameData) else {
            logger.error("Invalid binary frame (too short)")
            continue
          }

          // This should be a binary write
          if let writeInfo = await pendingWrites.remove(id) {
            let response = await handler.handleBinaryWrite(id: id, path: writeInfo.path, data: payload, createDirs: writeInfo.createDirs)
            let responseData = try JSONEncoder().encode(response)
            try await outbound.write(.text(String(decoding: responseData, as: UTF8.self)))
          } else {
            logger.debug("Binary frame for unknown id \(id)")
          }
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
