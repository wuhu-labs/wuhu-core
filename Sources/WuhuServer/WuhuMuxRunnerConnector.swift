import Foundation
import Logging
import Mux
import MuxTCP
import WuhuCore

/// Connects the server OUT to remote runners over TCP mux.
enum WuhuMuxRunnerConnector {

  /// Connect to a remote runner and register it in the registry.
  /// Runs until the mux session closes or is cancelled.
  /// Returns true if a connection was established.
  @discardableResult
  static func connect(
    name: String,
    host: String,
    port: Int,
    registry: RunnerRegistry,
    logger: Logger,
  ) async -> Bool {
    logger.info("Connecting to mux runner '\(name)' at \(host):\(port)")

    do {
      let connection = try await TCPConnector.connect(host: host, port: port)
      let session = MuxSession(connection: connection, role: .initiator)
      let runTask = Task { try await session.run() }

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
        runTask.cancel()
        return false
      }
      let runnerHello = try MuxRunnerCodec.decode(HelloResponse.self, from: payload)
      guard runnerHello.version == muxRunnerProtocolVersion else {
        logger.error("Runner '\(name)' has protocol version \(runnerHello.version), expected \(muxRunnerProtocolVersion)")
        await session.close()
        runTask.cancel()
        return false
      }

      logger.info("Mux runner '\(runnerHello.runnerName)' connected (v\(runnerHello.version))")

      let client = MuxRunnerClient(name: runnerHello.runnerName, session: session)
      await registry.register(client)

      defer {
        Task {
          await registry.remove(.remote(name: runnerHello.runnerName))
          logger.info("Mux runner '\(runnerHello.runnerName)' disconnected")
        }
      }

      // Block until session ends
      try? await runTask.value
      await session.close()
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
