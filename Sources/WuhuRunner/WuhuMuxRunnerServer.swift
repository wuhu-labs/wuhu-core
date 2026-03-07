import Foundation
import Logging
import Mux
import MuxTCP
import WuhuCore

/// Runs a mux-based runner server that accepts TCP connections from a Wuhu server.
///
/// This is the runner-side counterpart to `WuhuMuxRunnerConnector`.
/// The runner listens on a TCP port, accepts mux sessions, performs hello
/// exchange, and then serves RPC requests.
public struct WuhuMuxRunnerServer: Sendable {
  public init() {}

  public func run(config: WuhuRunnerConfig) async throws {
    let runner = LocalRunner()
    let host = config.listen?.host ?? "0.0.0.0"
    let muxPort = (config.listen?.port ?? 5531) + 1 // mux port = ws port + 1

    let logger = Logger(label: "WuhuRunner")
    logger.info("Starting mux runner '\(config.name)' on \(host):\(muxPort)")

    let listener = try await TCPListener.bind(host: host, port: muxPort)

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
