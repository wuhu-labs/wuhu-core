import Foundation
import HummingbirdWSClient
import Logging
import WuhuCore

/// Manages server-side connections to remote runners.
/// The server connects OUT to runners listed in config.
enum WuhuRunnerConnector {
  /// Connect to a remote runner and register it in the registry.
  /// Runs until the WebSocket connection closes or is cancelled.
  static func connect(
    name: String,
    address: String,
    registry: RunnerRegistry,
    logger: Logger,
  ) async {
    let wsURL = wsURLFromAddress(address, path: "/v1/runner/ws")
    logger.info("Connecting to runner '\(name)' at \(wsURL)")

    do {
      try await WebSocketClient.connect(url: wsURL, logger: logger) { inbound, outbound, _ in
        // Wait for hello from runner
        var iter = inbound.messages(maxSize: 64 * 1024 * 1024).makeAsyncIterator()
        guard let helloMsg = try await iter.next() else {
          logger.error("Runner '\(name)' closed before hello")
          return
        }
        guard case let .text(helloText) = helloMsg,
              let helloData = helloText.data(using: .utf8),
              let hello = try? JSONDecoder().decode(RunnerResponse.self, from: helloData),
              case let .hello(runnerName, version) = hello
        else {
          logger.error("Runner '\(name)' sent invalid hello")
          return
        }
        guard version == runnerProtocolVersion else {
          logger.error("Runner '\(name)' has protocol version \(version), expected \(runnerProtocolVersion)")
          return
        }

        logger.info("Runner '\(runnerName)' connected (protocol v\(version))")

        // Create connection + RemoteRunnerClient
        let connection = RunnerConnection(runnerName: runnerName)
        await connection.setSendMessage { text in
          try await outbound.write(.text(text))
        }

        let client = RemoteRunnerClient(name: runnerName, connection: connection)
        await registry.register(client)

        defer {
          Task {
            await connection.close()
            await registry.remove(.remote(name: runnerName))
            logger.info("Runner '\(runnerName)' disconnected")
          }
        }

        // Forward incoming messages to connection
        while let message = try await iter.next() {
          guard case let .text(text) = message else { continue }
          guard let data = text.data(using: .utf8) else { continue }
          do {
            let response = try JSONDecoder().decode(RunnerResponse.self, from: data)
            await connection.handleResponse(response)
          } catch {
            logger.debug("Failed to decode runner message: \(error)")
          }
        }
      }
    } catch {
      logger.error("Failed to connect to runner '\(name)': \(error)")
    }
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
          await connect(name: runner.name, address: runner.address, registry: registry, logger: logger)

          // Connection dropped — wait and retry
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
