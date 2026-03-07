import Foundation
import Logging
import Mux
import MuxTCP
import NIOCore
import WuhuCore

/// Accepts incoming TCP mux connections from runners that connect TO the server.
///
/// Runners connect to a TCP port, establish a mux session, perform a hello
/// exchange, and then serve RPC requests over mux streams.
enum WuhuMuxRunnerAcceptor {

  /// Start listening for incoming mux runner connections.
  /// Returns a task that runs the accept loop.
  static func start(
    host: String,
    port: Int,
    registry: RunnerRegistry,
    logger: Logger,
  ) -> Task<Void, Never> {
    Task {
      do {
        let listener = try await TCPListener.bind(host: host, port: port)
        logger.info("Mux runner acceptor listening on \(host):\(port)")

        for await connection in listener.connections {
          let registry = registry
          let logger = logger
          Task {
            await handleConnection(connection, registry: registry, logger: logger)
          }
        }
      } catch {
        logger.error("Mux runner acceptor failed: \(error)")
      }
    }
  }

  private static func handleConnection(
    _ connection: TCPConnection,
    registry: RunnerRegistry,
    logger: Logger,
  ) async {
    let session = MuxSession(connection: connection, role: .responder)
    let runTask = Task { try await session.run() }
    defer { runTask.cancel() }

    do {
      let hello = try await MuxRunnerHello.receiveFromRunner(session: session, serverName: "wuhu-server")
      let runnerName = hello.runnerName
      logger.info("Incoming mux runner '\(runnerName)' connected (v\(hello.version))")

      let client = MuxRunnerClient(name: runnerName, session: session)
      let registered = await registry.registerIncoming(client, name: runnerName)

      guard registered else {
        logger.warning("Incoming mux runner '\(runnerName)' rejected: runner with same name already connected")
        await session.close()
        return
      }

      defer {
        Task {
          await registry.remove(.remote(name: runnerName))
          logger.info("Incoming mux runner '\(runnerName)' disconnected")
        }
      }

      // Keep alive until session ends
      try? await runTask.value
    } catch {
      logger.error("Mux runner connection failed: \(error)")
      await session.close()
    }
  }
}
