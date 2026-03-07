import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
import MuxWebSocket
import WuhuCore

/// Creates a WebSocket router that accepts incoming mux runner connections.
///
/// Runners connect to the server's HTTP port via WebSocket upgrade on
/// `/v1/runner/mux`, establish a mux session, perform a hello exchange,
/// and then serve RPC requests over mux streams.
enum WuhuMuxRunnerAcceptor {
  /// Build a WebSocket router with the runner acceptor route.
  /// The returned router should be passed to `.http1WebSocketUpgrade(webSocketRouter:)`.
  static func webSocketRouter(
    registry: RunnerRegistry,
    logger: Logger
  ) -> Router<BasicWebSocketRequestContext> {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)

    wsRouter.ws("v1/runner/mux") { _, _ in
      .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
      let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
      await handleConnection(conn, registry: registry, logger: logger)
    }

    return wsRouter
  }

  private static func handleConnection(
    _ connection: WebSocketConnection,
    registry: RunnerRegistry,
    logger: Logger
  ) async {
    let session = MuxSession(connection: connection, role: .responder)
    let runTask = Task { try await session.run() }
    defer { runTask.cancel() }

    do {
      let hello = try await MuxRunnerHello.receiveHello(session: session, localName: "wuhu-server")
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
