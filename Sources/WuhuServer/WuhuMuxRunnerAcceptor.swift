import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import Mux
import MuxWebSocket
import WuhuCore

enum WuhuMuxRunnerAcceptor {
  static func webSocketRouter(
    registry: RunnerRegistry,
    callbacks: any RunnerCallbacks,
    logger: Logger,
  ) -> Router<BasicWebSocketRequestContext> {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)

    wsRouter.ws("v1/runner/mux") { _, _ in
      .upgrade([:])
    } onUpgrade: { inbound, outbound, _ in
      let conn = WebSocketConnection(inbound: inbound, outbound: outbound)
      await handleConnection(conn, registry: registry, callbacks: callbacks, logger: logger)
    }

    return wsRouter
  }

  private static func handleConnection(
    _ connection: WebSocketConnection,
    registry: RunnerRegistry,
    callbacks: any RunnerCallbacks,
    logger: Logger,
  ) async {
    let session = MuxSession(connection: connection, role: .responder)
    let runTask = Task { try await session.run() }
    defer { runTask.cancel() }

    do {
      let hello = try await MuxRunnerHello.receiveHello(session: session, localName: "wuhu-server")
      let runnerName = hello.runnerName
      logger.info("Incoming mux runner '\(runnerName)' connected (v\(hello.version))")

      let client = MuxRunnerClient(name: runnerName, session: session)
      await client.setCallbacks(callbacks)
      let callbackTask = Task { await client.startCallbackListener() }
      defer { callbackTask.cancel() }

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

      try? await runTask.value
    } catch {
      logger.error("Mux runner connection failed: \(String(describing: error))")
      await session.close()
    }
  }
}
