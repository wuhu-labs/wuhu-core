import Foundation
import Logging
import Mux
import MuxWebSocket
import WSClient
import WuhuCore

enum WuhuMuxRunnerConnector {
  @discardableResult
  static func connect(
    name: String,
    host: String,
    port: Int,
    registry: RunnerRegistry,
    callbacks: any RunnerCallbacks,
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
          logger.error("Runner '\(name)' rejected hello: \(String(decoding: Data(payload), as: UTF8.self))")
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

        let client = MuxRunnerClient(name: runnerHello.runnerName, session: session)
        await client.setCallbacks(callbacks)
        let callbackTask = Task { await client.startCallbackListener() }
        defer { callbackTask.cancel() }

        await registry.register(client)

        try? await runTask.value
        await session.close()

        await registry.remove(.remote(name: runnerHello.runnerName))
        logger.info("Mux runner '\(runnerHello.runnerName)' disconnected")
      }
      return true
    } catch {
      logger.error("Failed to connect to mux runner '\(name)': \(String(describing: error))")
      return false
    }
  }

  static func connectAll(
    runners: [(name: String, host: String, port: Int)],
    registry: RunnerRegistry,
    callbacks: any RunnerCallbacks,
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
            callbacks: callbacks,
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
