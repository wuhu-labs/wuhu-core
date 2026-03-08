import Foundation
import Logging
import Mux
import MuxWebSocket
import WSClient
import WuhuCore

/// Connects the server OUT to remote runners over WebSocket mux.
enum WuhuMuxRunnerConnector {
  /// Connect to a remote runner and register it in the registry.
  /// Runs until the mux session closes or is cancelled.
  /// Returns true if a connection was established and completed normally.
  @discardableResult
  static func connect(
    name: String,
    host: String,
    port: Int,
    registry: RunnerRegistry,
    callbackBridge: BashCallbackBridge,
    logger: Logger,
  ) async -> Bool {
    logger.info("Connecting to mux runner '\(name)' at \(host):\(port)")

    do {
      try await WebSocketClient.connect(
        url: .init("ws://\(host):\(port)/v1/runner/mux"),
        logger: logger,
      ) { inbound, outbound, _ in
        let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
        let session = MuxSession(connection: conn, role: .initiator)
        let runTask = Task { try await session.run() }
        defer { runTask.cancel() }

        // Hello exchange — we send hello first as the initiator
        let helloStream = try await session.open()
        let hello = HelloResponse(runnerName: "wuhu-server", version: muxRunnerProtocolVersion)
        try await MuxRunnerCodec.writeRequest(helloStream, op: .hello, payload: hello)
        try await helloStream.finish()

        let reader = MuxStreamReader(stream: helloStream)
        let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
        guard ok else {
          let msg = String(decoding: Data(payload), as: UTF8.self)
          logger.error("Runner '\(name)' rejected hello: \(msg)")
          await session.close()
          return
        }
        let runnerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
        guard runnerHello.version == muxRunnerProtocolVersion else {
          logger.error("Runner '\(name)' has protocol version \(runnerHello.version), expected \(muxRunnerProtocolVersion)")
          await session.close()
          return
        }

        logger.info("Mux runner '\(runnerHello.runnerName)' connected (v\(runnerHello.version))")

        let client = MuxRunnerCommandsClient(name: runnerHello.runnerName, session: session)
        await client.startCallbackHandler(callbacks: callbackBridge)
        await registry.register(client)

        // Block until session ends
        try? await runTask.value
        await client.stopCallbackHandler()
        await session.close()

        await registry.remove(.remote(name: runnerHello.runnerName))
        logger.info("Mux runner '\(runnerHello.runnerName)' disconnected")
      }
      // If we get here, WebSocket connected and ran to completion
      return true
    } catch {
      logger.error("Failed to connect to mux runner '\(name)': \(error)")
      return false
    }
  }

  /// Start background tasks to connect to all configured mux runners with reconnection.
  static func connectAll(
    runners: [(name: String, host: String, port: Int)],
    registry: RunnerRegistry,
    callbackBridge: BashCallbackBridge,
    logger: Logger,
  ) -> [Task<Void, Never>] {
    runners.map { runner in
      Task {
        var backoff: UInt64 = 1_000_000_000
        let maxBackoff: UInt64 = 30_000_000_000

        while !Task.isCancelled {
          let connected = await connect(
            name: runner.name,
            host: runner.host,
            port: runner.port,
            registry: registry,
            callbackBridge: callbackBridge,
            logger: logger,
          )

          if connected { backoff = 1_000_000_000 }
          if Task.isCancelled { break }
          logger.info("Will reconnect to mux runner '\(runner.name)' in \(backoff / 1_000_000_000)s")
          try? await Task.sleep(nanoseconds: backoff)
          backoff = min(backoff * 2, maxBackoff)
        }
      }
    }
  }
}
