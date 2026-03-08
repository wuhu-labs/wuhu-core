import Foundation
import Mux

/// Runner-side: accepts inbound command streams from the server and
/// dispatches them to a `RunnerCommands` implementation (typically `LocalRunner`).
///
/// Also provides `MuxRunnerCallbacksClient` which implements `RunnerCallbacks`
/// by opening streams back to the server for bash output/finished callbacks.
public enum MuxRunnerCommandsServer {
  /// Run the handler loop: accept inbound command streams and dispatch them.
  /// Returns when the session closes or is cancelled.
  public static func serve(session: MuxSession, commands: any RunnerCommands, name: String) async {
    for await stream in session.inbound {
      let commands = commands
      let name = name
      Task {
        await handleStream(stream, commands: commands, name: name)
      }
    }
  }

  /// Handle a single inbound command stream (one RPC call).
  private static func handleStream(_ stream: MuxStream, commands: any RunnerCommands, name: String) async {
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
        let resp = HelloResponse(runnerName: name, version: muxRunnerProtocolVersion)
        try await MuxRunnerCodec.writeSuccess(stream, op: .hello, payload: resp)

      case .startBash:
        let req = try MuxRunnerCodec.decode(StartBashRequest.self, from: payload)
        do {
          let result = try await commands.startBash(tag: req.tag, command: req.command, cwd: req.cwd, timeout: req.timeout)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: result)
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .cancelBash:
        let req = try MuxRunnerCodec.decode(CancelBashRequest.self, from: payload)
        do {
          let result = try await commands.cancelBash(tag: req.tag)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: result)
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .read:
        let req = try MuxRunnerCodec.decode(ReadRequest.self, from: payload)
        do {
          if req.binary {
            let data = try await commands.readData(path: req.path)
            let resp = ReadResponse(size: data.count)
            try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: resp)
            try await MuxRunnerCodec.writeBinary(stream, data: data)
          } else {
            let content = try await commands.readString(path: req.path, encoding: .utf8)
            let resp = ReadResponse(content: content, size: content.utf8.count)
            try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: resp)
          }
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .write:
        let req = try MuxRunnerCodec.decode(WriteRequest.self, from: payload)
        do {
          if let content = req.content {
            try await commands.writeString(path: req.path, content: content, createIntermediateDirectories: req.createDirs, encoding: .utf8)
            try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: WriteResponse(bytesWritten: content.utf8.count))
          } else {
            let data = try await MuxRunnerCodec.readBinary(reader)
            try await commands.writeData(path: req.path, data: data, createIntermediateDirectories: req.createDirs)
            try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: WriteResponse(bytesWritten: data.count))
          }
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .exists:
        let req = try MuxRunnerCodec.decode(ExistsRequest.self, from: payload)
        do {
          let existence = try await commands.exists(path: req.path)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: ExistsResponse(existence: existence))
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .ls:
        let req = try MuxRunnerCodec.decode(LsRequest.self, from: payload)
        do {
          let entries = try await commands.listDirectory(path: req.path)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: LsResponse(entries: entries))
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .enumerate:
        let req = try MuxRunnerCodec.decode(EnumerateRequest.self, from: payload)
        do {
          let entries = try await commands.enumerateDirectory(root: req.root)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: EnumerateResponse(entries: entries))
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .mkdir:
        let req = try MuxRunnerCodec.decode(MkdirRequest.self, from: payload)
        do {
          try await commands.createDirectory(path: req.path, withIntermediateDirectories: req.recursive)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: MkdirResponse())
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .find:
        let req = try MuxRunnerCodec.decode(FindParams.self, from: payload)
        do {
          let result = try await commands.find(params: req)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: result)
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .grep:
        let req = try MuxRunnerCodec.decode(GrepParams.self, from: payload)
        do {
          let result = try await commands.grep(params: req)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: result)
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .materialize:
        let req = try MuxRunnerCodec.decode(MaterializeRequest.self, from: payload)
        do {
          let result = try await commands.materialize(params: req)
          try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: result)
        } catch {
          try await MuxRunnerCodec.writeError(stream, op: op, message: String(describing: error))
        }

      case .bashOutput, .bashFinished:
        // These are callback ops — shouldn't arrive on the command channel
        try await MuxRunnerCodec.writeError(stream, op: op, message: "Callback op received on command channel")
      }

      try await stream.finish()
    } catch {
      try? await stream.reset()
    }
  }
}

// MARK: - MuxRunnerCallbacksClient

/// Runner-side: implements `RunnerCallbacks` by opening mux streams
/// back to the server for bash output and finished callbacks.
public final class MuxRunnerCallbacksClient: RunnerCallbacks, @unchecked Sendable {
  private let session: MuxSession

  public init(session: MuxSession) {
    self.session = session
  }

  public func bashOutput(tag: String, chunk: String) async throws {
    try await sendCallback(.bashOutput, payload: BashOutputCallback(tag: tag, chunk: chunk))
  }

  public func bashFinished(tag: String, result: BashResult) async throws {
    try await sendCallback(.bashFinished, payload: BashFinishedCallback(tag: tag, result: result))
  }

  private func sendCallback(_ op: MuxRunnerOp, payload: some Encodable & Sendable) async throws {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: op, payload: payload)
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, respPayload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      let message = String(decoding: Data(respPayload), as: UTF8.self)
      throw RunnerError.requestFailed(message: "Callback failed: \(message)")
    }
  }
}
