import Foundation
import Logging
import Mux

private let logger = DebugLogger.logger("MuxRunnerHandler")

/// Accepts inbound mux streams and dispatches each to the appropriate
/// `Runner` method via `RunnerServerHandler`.
///
/// Each inbound stream is one RPC call. The handler reads the request,
/// dispatches it, writes the response, and closes the stream.
///
/// ## v3 protocol
///
/// Bash callbacks (bashOutput, bashFinished) are pushed from the runner
/// back to the server via `MuxCallbackSender`, which opens outbound
/// streams on the same session.
public enum MuxRunnerHandler {
  /// Run the handler loop: accept inbound streams and dispatch them.
  /// Returns when the session closes or is cancelled.
  ///
  /// - Parameter callbacks: Optional pre-configured callbacks. When provided,
  ///   `setCallbacks` is **not** called on the runner — the caller is responsible
  ///   for routing callbacks (e.g. through a `WorkerCallbackBuffer`).
  ///   When `nil` (the default), a `MuxCallbackSender` is created and installed
  ///   as usual.
  public static func serve(
    session: MuxSession,
    runner: any Runner,
    name: String,
    callbacks: (any RunnerCallbacks)? = nil,
  ) async {
    let handler = RunnerServerHandler(runner: runner, name: name)

    if callbacks == nil {
      // Set up callback sender so the runner can push bash results back to the server
      let callbackSender = MuxCallbackSender(session: session, runnerName: name)
      await runner.setCallbacks(callbackSender)
    }

    for await stream in session.inbound {
      let handler = handler
      let name = name
      Task {
        await handleStream(stream, handler: handler, runnerName: name)
      }
    }
  }

  /// Handle a single inbound stream (one RPC call).
  private static func handleStream(_ stream: MuxStream, handler: RunnerServerHandler, runnerName: String) async {
    do {
      let reader = MuxStreamReader(stream: stream)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      switch op {
      case .hello:
        let peerHello: HelloResponse? = payload.isEmpty ? nil : try? MuxRunnerCodec.decode(HelloResponse.self, from: payload)
        if let peerHello, peerHello.version != muxRunnerProtocolVersion {
          try await MuxRunnerCodec.writeError(stream, op: .hello, message: "Version mismatch: expected \(muxRunnerProtocolVersion), got \(peerHello.version)")
          try await stream.finish()
          return
        }
        let resp = HelloResponse(runnerName: handler.runnerName, version: muxRunnerProtocolVersion)
        try await MuxRunnerCodec.writeSuccess(stream, op: .hello, payload: resp)

      case .startBash:
        let req = try MuxRunnerCodec.decode(StartBashRequest.self, from: payload)
        let commandPreview = String(req.command.prefix(50))
        logger.debug(
          "runner received startBash request",
          metadata: [
            "tag": "\(req.tag)",
            "runner": "\(runnerName)",
            "cwd": "\(req.cwd)",
            "timeout": "\(req.timeout.map { String($0) } ?? "none")",
            "commandPreview": "\(commandPreview)",
          ],
        )
        let (response, _) = await handler.handle(request: .startBash(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)
        if case let .startBash(_, result) = response {
          switch result {
          case let .success(started):
            logger.debug(
              "runner sent startBash response",
              metadata: [
                "tag": "\(req.tag)",
                "runner": "\(runnerName)",
                "alreadyRunning": "\(started.alreadyRunning)",
              ],
            )
          case let .failure(error):
            logger.debug(
              "runner startBash failed",
              metadata: [
                "tag": "\(req.tag)",
                "runner": "\(runnerName)",
                "error": "\(error.message)",
              ],
            )
          }
        }

      case .cancelBash:
        let req = try MuxRunnerCodec.decode(CancelBashRequest.self, from: payload)
        logger.debug(
          "runner received cancelBash request",
          metadata: [
            "tag": "\(req.tag)",
            "runner": "\(runnerName)",
          ],
        )
        let (response, _) = await handler.handle(request: .cancelBash(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .read:
        let req = try MuxRunnerCodec.decode(ReadRequest.self, from: payload)
        logger.debug("runner received read", metadata: ["runner": "\(runnerName)", "path": "\(req.path)"])
        let (response, binaryData) = await handler.handle(request: .read(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)
        if let data = binaryData {
          try await MuxRunnerCodec.writeBinary(stream, data: data)
        }

      case .write:
        let req = try MuxRunnerCodec.decode(WriteRequest.self, from: payload)
        logger.debug("runner received write", metadata: ["runner": "\(runnerName)", "path": "\(req.path)"])
        if req.content != nil {
          let (response, _) = await handler.handle(request: .write(id: "", req))
          try await writeRunnerResponse(stream, op: op, response: response)
        } else {
          let data = try await MuxRunnerCodec.readBinary(reader)
          let response = await handler.handleBinaryWrite(id: "", path: req.path, data: data, createDirs: req.createDirs)
          try await writeRunnerResponse(stream, op: op, response: response)
        }

      case .exists:
        let req = try MuxRunnerCodec.decode(ExistsRequest.self, from: payload)
        logger.debug("runner received exists", metadata: ["runner": "\(runnerName)", "path": "\(req.path)"])
        let (response, _) = await handler.handle(request: .exists(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .ls:
        let req = try MuxRunnerCodec.decode(LsRequest.self, from: payload)
        logger.debug("runner received ls", metadata: ["runner": "\(runnerName)", "path": "\(req.path)"])
        let (response, _) = await handler.handle(request: .ls(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .enumerate:
        let req = try MuxRunnerCodec.decode(EnumerateRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .enumerate(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .mkdir:
        let req = try MuxRunnerCodec.decode(MkdirRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .mkdir(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .find:
        let req = try MuxRunnerCodec.decode(FindParams.self, from: payload)
        logger.debug("runner received find", metadata: ["runner": "\(runnerName)", "root": "\(req.root)", "pattern": "\(req.pattern)"])
        let (response, _) = await handler.handle(request: .find(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .grep:
        let req = try MuxRunnerCodec.decode(GrepParams.self, from: payload)
        logger.debug("runner received grep", metadata: ["runner": "\(runnerName)", "root": "\(req.root)", "pattern": "\(req.pattern)"])
        let (response, _) = await handler.handle(request: .grep(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .materialize:
        let req = try MuxRunnerCodec.decode(MaterializeRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .materialize(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .bashOutput, .bashFinished:
        // These are callback ops — they flow runner→server, not server→runner.
        // If we receive them here, it's an error.
        try await MuxRunnerCodec.writeError(stream, op: op, message: "Callback ops should not be sent as requests")
      }

      try await stream.finish()
    } catch {
      try? await stream.reset()
    }
  }

  /// Convert a RunnerResponse into a mux response frame.
  private static func writeRunnerResponse(_ stream: MuxStream, op: MuxRunnerOp, response: RunnerResponse) async throws {
    switch response {
    case let .hello(resp):
      try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: resp)
    case let .startBash(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .cancelBash(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .read(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .write(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .exists(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .ls(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .enumerate(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .mkdir(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .find(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .grep(_, result):
      try await writeResult(stream, op: op, result: result)
    case let .materialize(_, result):
      try await writeResult(stream, op: op, result: result)
    }
  }

  private static func writeResult(_ stream: MuxStream, op: MuxRunnerOp, result: Result<some Encodable, RunnerWireError>) async throws {
    switch result {
    case let .success(value):
      try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: value)
    case let .failure(error):
      try await MuxRunnerCodec.writeError(stream, op: op, message: error.message)
    }
  }
}

// MARK: - MuxCallbackSender

/// Runner-side actor that pushes bash callbacks to the server
/// by opening outbound mux streams.
///
/// Each callback opens a new stream, writes the op + payload,
/// reads an ack response, and closes.
public actor MuxCallbackSender: RunnerCallbacks {
  private let session: MuxSession
  private let runnerName: String

  public init(session: MuxSession, runnerName: String = "unknown") {
    self.session = session
    self.runnerName = runnerName
  }

  public func bashOutput(tag: String, chunk: String) async throws {
    logger.debug(
      "runner sending bashOutput callback",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
        "chunkSize": "\(chunk.count)",
      ],
    )
    let payload = BashOutputChunk(tag: tag, chunk: chunk)
    try await sendCallback(op: .bashOutput, payload: payload)
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    logger.debug(
      "runner sending bashFinished callback",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
        "exitCode": "\(result.exitCode)",
        "timedOut": "\(result.timedOut)",
        "terminated": "\(result.terminated)",
        "outputSize": "\(result.output.count)",
      ],
    )
    let payload = BashFinished(tag: tag, result: result)
    try await sendCallback(op: .bashFinished, payload: payload)
  }

  private func sendCallback(op: MuxRunnerOp, payload: some Encodable & Sendable) async throws {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: op, payload: payload)
    try await stream.finish()
    // Read ack response
    let reader = MuxStreamReader(stream: stream)
    _ = try await MuxRunnerCodec.readResponse(reader)
  }
}
