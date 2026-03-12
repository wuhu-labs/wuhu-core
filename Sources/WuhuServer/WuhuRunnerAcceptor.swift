import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOWebSocket
import WuhuCore

/// Handles incoming WebSocket connections from runners that connect TO the server.
/// This is the reverse of `WuhuRunnerConnector` (where the server connects out).
///
/// Runners connect to `GET /v1/runners/ws`, send a `hello` with their name,
/// and then receive `RunnerRequest`s and respond with `RunnerResponse`s.
enum WuhuRunnerAcceptor {
  /// Build a WebSocket router that accepts incoming runner connections.
  /// Attach this to the Hummingbird application via `http1WebSocketUpgrade`.
  static func wsRouter(
    registry: RunnerRegistry,
    logger: Logger,
  ) -> Router<BasicWebSocketRequestContext> {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)

    wsRouter.ws("/v1/runners/ws") { _, _ in
      .upgrade()
    } onUpgrade: { inbound, outbound, _ in
      let logger = logger

      // Wait for hello from the runner
      var iter = inbound.messages(maxSize: 256 * 1024 * 1024).makeAsyncIterator()
      guard let helloMsg = try await iter.next() else {
        logger.error("Incoming runner closed before hello")
        return
      }
      guard case let .text(helloText) = helloMsg,
            let helloData = helloText.data(using: .utf8),
            let hello = try? JSONDecoder().decode(RunnerResponse.self, from: helloData),
            case let .hello(helloResp) = hello
      else {
        logger.error("Incoming runner sent invalid hello")
        return
      }
      guard helloResp.version == runnerProtocolVersion else {
        logger.error("Incoming runner '\(helloResp.runnerName)' has protocol version \(helloResp.version), expected \(runnerProtocolVersion)")
        return
      }

      let runnerName = helloResp.runnerName
      logger.info("Incoming runner '\(runnerName)' connected (protocol v\(helloResp.version))")

      // Create connection + RemoteRunnerClient
      let connection = RunnerConnection(runnerName: runnerName)
      await connection.setSend(
        text: { text in try await outbound.write(.text(text)) },
        binary: { data in try await outbound.write(.binary(ByteBuffer(data: data))) },
      )

      let client = RemoteRunnerClient(name: runnerName, connection: connection)
      let registered = await registry.registerIncoming(client, name: runnerName)

      guard registered else {
        logger.warning("Incoming runner '\(runnerName)' rejected: declared runner with same name already connected")
        await connection.close()
        return
      }

      defer {
        Task {
          await connection.close()
          await registry.remove(.remote(name: runnerName))
          logger.info("Incoming runner '\(runnerName)' disconnected")
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
            logger.debug("Failed to decode incoming runner text message: \(error)")
          }

        case let .binary(buffer):
          let data = Data(buffer: buffer)
          await connection.handleBinaryFrame(data)
        }
      }
    }

    return wsRouter
  }
}
