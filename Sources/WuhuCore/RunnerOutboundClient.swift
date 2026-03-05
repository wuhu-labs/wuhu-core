#if canImport(Darwin)

  import Foundation
  import Logging

  /// Connects a local runner to a remote Wuhu server by establishing a WebSocket
  /// connection to the server's `/v1/runners/ws` endpoint.
  ///
  /// The runner sends a `hello` with its name, then receives `RunnerRequest`s
  /// and sends back `RunnerResponse`s. This is the reverse of the existing
  /// `WuhuRunnerConnector` (where the server connects out to the runner).
  ///
  /// Used by the Mac app's embedded runner to register itself with the server.
  ///
  /// Only available on Apple platforms (uses `URLSessionWebSocketTask`).
  public enum RunnerOutboundClient {
    /// Configuration for connecting a runner to a server.
    public struct Config: Sendable {
      public var runnerName: String
      public var serverURL: String
      public var logger: Logger
      /// Called when the connection is established (hello sent successfully).
      public var onConnected: (@Sendable () -> Void)?
      /// Called when the connection is lost.
      public var onDisconnected: (@Sendable () -> Void)?

      public init(
        runnerName: String,
        serverURL: String,
        logger: Logger = Logger(label: "RunnerOutbound"),
        onConnected: (@Sendable () -> Void)? = nil,
        onDisconnected: (@Sendable () -> Void)? = nil,
      ) {
        self.runnerName = runnerName
        self.serverURL = serverURL
        self.logger = logger
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
      }
    }

    /// Connect to the server and run the runner loop until disconnected or cancelled.
    /// Returns `true` if a connection was established (and later dropped),
    /// `false` if it never connected.
    ///
    /// This function blocks until the WebSocket closes. Wrap in a `Task` for async usage.
    /// For automatic reconnection, use `connectWithReconnect`.
    @discardableResult
    public static func connect(config: Config, runner: any Runner) async -> Bool {
      let wsURL = wsURLFromAddress(config.serverURL, path: "/v1/runners/ws")
      let logger = config.logger
      logger.info("Connecting runner '\(config.runnerName)' to server at \(wsURL)")

      guard let url = URL(string: wsURL) else {
        logger.error("Invalid WebSocket URL: \(wsURL)")
        return false
      }

      let session = URLSession(configuration: .default)
      let wsTask = session.webSocketTask(with: url)
      wsTask.maximumMessageSize = 256 * 1024 * 1024
      wsTask.resume()

      let handler = RunnerServerHandler(runner: runner, name: config.runnerName)

      // Send hello
      let hello = RunnerResponse.hello(HelloResponse(runnerName: config.runnerName, version: runnerProtocolVersion))
      guard let helloData = try? JSONEncoder().encode(hello) else {
        logger.error("Failed to encode hello")
        wsTask.cancel(with: .internalServerError, reason: nil)
        return false
      }
      do {
        try await wsTask.send(.string(String(decoding: helloData, as: UTF8.self)))
      } catch {
        logger.error("Failed to send hello: \(error)")
        wsTask.cancel(with: .internalServerError, reason: nil)
        return false
      }

      logger.info("Runner '\(config.runnerName)' connected to server")
      config.onConnected?()

      // Track pending binary writes: id → (path, createDirs)
      actor PendingBinaryWrites {
        var writes: [String: (path: String, createDirs: Bool)] = [:]
        func set(_ id: String, path: String, createDirs: Bool) {
          writes[id] = (path, createDirs)
        }

        func remove(_ id: String) -> (path: String, createDirs: Bool)? {
          writes.removeValue(forKey: id)
        }
      }

      let pendingWrites = PendingBinaryWrites()

      // Message loop
      do {
        while !Task.isCancelled {
          let message = try await wsTask.receive()

          switch message {
          case let .string(text):
            guard let data = text.data(using: .utf8) else { continue }
            do {
              let request = try JSONDecoder().decode(RunnerRequest.self, from: data)

              // If this is a binary write (content is nil), stash the write info and wait for binary frame
              if case let .write(id, p) = request, p.content == nil {
                await pendingWrites.set(id, path: p.path, createDirs: p.createDirs)
                continue
              }

              let (response, binaryData) = await handler.handle(request: request)
              let responseData = try JSONEncoder().encode(response)
              try await wsTask.send(.string(String(decoding: responseData, as: UTF8.self)))

              // Send companion binary frame if present (e.g., binary read response)
              if let binaryData, let id = response.responseID {
                let frame = RunnerBinaryFrame.encode(id: id, data: binaryData)
                try await wsTask.send(.data(frame))
              }
            } catch {
              logger.error("Failed to process runner request: \(error)")
            }

          case let .data(frameData):
            guard let (id, payload) = RunnerBinaryFrame.decode(frameData) else {
              logger.error("Invalid binary frame (too short)")
              continue
            }

            // This should be a binary write
            if let writeInfo = await pendingWrites.remove(id) {
              do {
                let response = await handler.handleBinaryWrite(id: id, path: writeInfo.path, data: payload, createDirs: writeInfo.createDirs)
                let responseData = try JSONEncoder().encode(response)
                try await wsTask.send(.string(String(decoding: responseData, as: UTF8.self)))
              } catch {
                logger.error("Failed to process binary write for \(id): \(error)")
              }
            } else {
              logger.debug("Binary frame for unknown id \(id)")
            }

          @unknown default:
            break
          }
        }
      } catch {
        logger.info("Runner '\(config.runnerName)' WebSocket closed: \(error)")
      }

      config.onDisconnected?()
      wsTask.cancel(with: .goingAway, reason: nil)
      return true
    }

    /// Connect with automatic reconnection on disconnect.
    /// Runs forever (until the returned Task is cancelled).
    public static func connectWithReconnect(config: Config, runner: any Runner) async {
      var backoff: UInt64 = 1_000_000_000 // 1s
      let maxBackoff: UInt64 = 30_000_000_000 // 30s

      while !Task.isCancelled {
        let connected = await connect(config: config, runner: runner)

        if connected {
          backoff = 1_000_000_000 // Reset backoff after successful connection
        }

        if Task.isCancelled { break }
        config.logger.info("Will reconnect runner '\(config.runnerName)' in \(backoff / 1_000_000_000)s")
        try? await Task.sleep(nanoseconds: backoff)
        backoff = min(backoff * 2, maxBackoff)
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

#endif
