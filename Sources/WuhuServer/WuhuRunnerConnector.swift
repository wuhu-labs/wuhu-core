import Foundation
import HummingbirdWSClient
import Logging
import NIOCore
import WSClient
import WuhuCore

/// Manages server-side connections to remote runners.
/// The server connects OUT to runners listed in config.
enum WuhuRunnerConnector {
  /// Connect to a remote runner and register it in the registry.
  /// Runs until the WebSocket connection closes or is cancelled.
  /// Returns true if a connection was established (and later dropped), false if it never connected.
  @discardableResult
  static func connect(
    name: String,
    address: String,
    registry: RunnerRegistry,
    logger: Logger,
  ) async -> Bool {
    let wsURL = wsURLFromAddress(address, path: "/v1/runner/ws")
    logger.info("Connecting to runner '\(name)' at \(wsURL)")
    nonisolated(unsafe) var didConnect = false

    let wsConfig = WebSocketClientConfiguration(
      maxFrameSize: 1 << 24, // 16 MB — must match the runner server setting
    )

    do {
      try await WebSocketClient.connect(url: wsURL, configuration: wsConfig, logger: logger) { inbound, outbound, _ in
        // Wait for hello from runner
        var iter = inbound.messages(maxSize: 256 * 1024 * 1024).makeAsyncIterator()
        guard let helloMsg = try await iter.next() else {
          logger.error("Runner '\(name)' closed before hello")
          return
        }
        guard case let .text(helloText) = helloMsg,
              let helloData = helloText.data(using: .utf8),
              let hello = try? JSONDecoder().decode(RunnerResponse.self, from: helloData),
              case let .hello(helloResp) = hello
        else {
          logger.error("Runner '\(name)' sent invalid hello")
          return
        }
        guard helloResp.version == runnerProtocolVersion else {
          logger.error("Runner '\(name)' has protocol version \(helloResp.version), expected \(runnerProtocolVersion)")
          return
        }

        logger.info("Runner '\(helloResp.runnerName)' connected (protocol v\(helloResp.version))")
        didConnect = true

        // Create connection + RemoteRunnerClient
        let connection = RunnerConnection(runnerName: helloResp.runnerName)
        await connection.setSend(
          text: { text in try await outbound.write(.text(text)) },
          binary: { data in try await outbound.write(.binary(ByteBuffer(data: data))) },
        )

        let client = RemoteRunnerClient(name: helloResp.runnerName, connection: connection)
        await registry.register(client)

        defer {
          Task {
            await connection.close()
            await registry.remove(.remote(name: helloResp.runnerName))
            logger.info("Runner '\(helloResp.runnerName)' disconnected")
          }
        }

        // Forward incoming messages to connection
        while let message = try await iter.next() {
          switch message {
          case let .text(text):
            guard let data = text.data(using: .utf8) else { continue }
            do {
              let response = try JSONDecoder().decode(RunnerResponse.self, from: data)
              await connection.handleResponse(response)
            } catch {
              logger.debug("Failed to decode runner text message: \(error)")
            }

          case let .binary(buffer):
            let data = Data(buffer: buffer)
            await connection.handleBinaryFrame(data)
          }
        }
      }
    } catch {
      logger.error("Failed to connect to runner '\(name)': \(error)")
    }
    return didConnect
  }

  /// Start background tasks to connect to all configured runners.
  /// Returns the tasks so they can be cancelled on shutdown.
  static func connectAll(
    runners: [WuhuServerConfig.Runner],
    registry: RunnerRegistry,
    logger: Logger,
  ) -> [Task<Void, Never>] {
    runners.map { runner in
      Task {
        // Reconnection loop with backoff
        var backoff: UInt64 = 1_000_000_000 // 1s
        let maxBackoff: UInt64 = 30_000_000_000 // 30s

        while !Task.isCancelled {
          let connected = await connect(name: runner.name, address: runner.address, registry: registry, logger: logger)

          // Reset backoff after successful connection (was connected then dropped)
          if connected {
            backoff = 1_000_000_000
          }

          // Connection dropped or failed — wait and retry
          if Task.isCancelled { break }
          logger.info("Will reconnect to runner '\(runner.name)' in \(backoff / 1_000_000_000)s")
          try? await Task.sleep(nanoseconds: backoff)
          backoff = min(backoff * 2, maxBackoff)
        }
      }
    }
  }

  private static func wsURLFromAddress(_ address: String, path: String) -> String {
    if address.hasPrefix("ws://") || address.hasPrefix("wss://") {
      return address + path
    }
    if address.hasPrefix("http://") {
      return "ws://" + address.dropFirst("http://".count) + path
    }
    if address.hasPrefix("https://") {
      return "wss://" + address.dropFirst("https://".count) + path
    }
    return "ws://\(address)\(path)"
  }
}
