import Foundation
import Mux

public enum MuxRunnerHandler {
  public static func serve(
    session: MuxSession,
    runner: any Runner,
    name: String,
    callbacks: (any RunnerCallbacks)? = nil,
  ) async {
    let handler = RunnerServerHandler(runner: runner, name: name)

    if callbacks == nil {
      await runner.setCallbacks(MuxCallbackSender(session: session))
    }

    for await stream in session.inbound {
      let handler = handler
      Task {
        await handleStream(stream, handler: handler)
      }
    }
  }

  private static func handleStream(_ stream: MuxStream, handler: RunnerServerHandler) async {
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
        try await MuxRunnerCodec.writeSuccess(
          stream,
          op: .hello,
          payload: HelloResponse(runnerName: handler.runnerName, version: muxRunnerProtocolVersion),
        )

      case .startBash:
        let req = try MuxRunnerCodec.decode(StartBashRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .startBash(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .cancelBash:
        let req = try MuxRunnerCodec.decode(CancelBashRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .cancelBash(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .read:
        let req = try MuxRunnerCodec.decode(ReadRequest.self, from: payload)
        let (response, binaryData) = await handler.handle(request: .read(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)
        if let data = binaryData {
          try await MuxRunnerCodec.writeBinary(stream, data: data)
        }

      case .write:
        let req = try MuxRunnerCodec.decode(WriteRequest.self, from: payload)
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
        let (response, _) = await handler.handle(request: .exists(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .ls:
        let req = try MuxRunnerCodec.decode(LsRequest.self, from: payload)
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
        let (response, _) = await handler.handle(request: .find(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .grep:
        let req = try MuxRunnerCodec.decode(GrepParams.self, from: payload)
        let (response, _) = await handler.handle(request: .grep(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .materialize:
        let req = try MuxRunnerCodec.decode(MaterializeRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .materialize(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .bashHeartbeat, .bashFinished:
        try await MuxRunnerCodec.writeError(stream, op: op, message: "Callback ops should not be sent as requests")
      }

      try await stream.finish()
    } catch {
      try? await stream.reset()
    }
  }

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

  private static func writeResult(
    _ stream: MuxStream,
    op: MuxRunnerOp,
    result: Result<some Encodable, RunnerWireError>,
  ) async throws {
    switch result {
    case let .success(value):
      try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: value)
    case let .failure(error):
      try await MuxRunnerCodec.writeError(stream, op: op, message: error.message)
    }
  }
}

public actor MuxCallbackSender: RunnerCallbacks {
  private let session: MuxSession

  public init(session: MuxSession) {
    self.session = session
  }

  public func bashHeartbeat(tag: String) async throws {
    try await sendCallback(op: .bashHeartbeat, payload: BashHeartbeat(tag: tag))
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    try await sendCallback(op: .bashFinished, payload: BashFinished(tag: tag, result: result))
  }

  private func sendCallback(op: MuxRunnerOp, payload: some Encodable & Sendable) async throws {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: op, payload: payload)
    try await stream.finish()
    let reader = MuxStreamReader(stream: stream)
    _ = try await MuxRunnerCodec.readResponse(reader)
  }
}
