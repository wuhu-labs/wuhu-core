import Foundation
import Mux

/// Accepts inbound mux streams and dispatches each to the appropriate
/// `Runner` method via `RunnerServerHandler`.
///
/// Each inbound stream is one RPC call. The handler reads the request,
/// dispatches it, writes the response, and closes the stream.
public enum MuxRunnerHandler {

  /// Run the handler loop: accept inbound streams and dispatch them.
  /// Returns when the session closes or is cancelled.
  public static func serve(session: MuxSession, runner: any Runner, name: String) async {
    let handler = RunnerServerHandler(runner: runner, name: name)

    for await stream in session.inbound {
      let handler = handler
      Task {
        await handleStream(stream, handler: handler)
      }
    }
  }

  /// Handle a single inbound stream (one RPC call).
  private static func handleStream(_ stream: MuxStream, handler: RunnerServerHandler) async {
    do {
      let reader = MuxStreamReader(stream: stream)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      switch op {
      case .hello:
        let _: HelloRequest? = payload.isEmpty ? nil : try? MuxRunnerCodec.decode(HelloRequest.self, from: payload)
        let resp = HelloResponse(runnerName: await handler.runnerName, version: runnerProtocolVersion)
        try await MuxRunnerCodec.writeSuccess(stream, op: .hello, payload: resp)

      case .bash:
        let req = try MuxRunnerCodec.decode(BashRequest.self, from: payload)
        let (response, _) = await handler.handle(request: .bash(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)

      case .read:
        let req = try MuxRunnerCodec.decode(ReadRequest.self, from: payload)
        let (response, binaryData) = await handler.handle(request: .read(id: "", req))
        try await writeRunnerResponse(stream, op: op, response: response)
        // If there's binary data, send it after the response frame
        if let data = binaryData {
          try await MuxRunnerCodec.writeBinary(stream, data: data)
        }

      case .write:
        let req = try MuxRunnerCodec.decode(WriteRequest.self, from: payload)
        if req.content != nil {
          // Text write — content is in the JSON payload
          let (response, _) = await handler.handle(request: .write(id: "", req))
          try await writeRunnerResponse(stream, op: op, response: response)
        } else {
          // Binary write — data follows as length-prefixed bytes on the stream
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
      }

      try await stream.finish()
    } catch {
      // Best effort — stream may already be closed
      try? await stream.reset()
    }
  }

  /// Convert a RunnerResponse (from the existing handler) into a mux response frame.
  private static func writeRunnerResponse(_ stream: MuxStream, op: MuxRunnerOp, response: RunnerResponse) async throws {
    // Extract the result from the response enum
    switch response {
    case let .hello(resp):
      try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: resp)

    case let .bash(_, result):
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

  private static func writeResult<T: Encodable>(_ stream: MuxStream, op: MuxRunnerOp, result: Result<T, RunnerWireError>) async throws {
    switch result {
    case let .success(value):
      try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: value)
    case let .failure(error):
      try await MuxRunnerCodec.writeError(stream, op: op, message: error.message)
    }
  }
}
