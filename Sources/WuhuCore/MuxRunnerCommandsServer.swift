import Foundation
import Mux

/// Runner-side mux handler that accepts inbound command streams and dispatches
/// them to a `RunnerCommands` implementation (typically `LocalRunner`).
///
/// Each inbound stream is one RPC call. The handler reads the request,
/// dispatches it, writes the response, and closes the stream.
///
/// For bash: calls `startBash` then `waitForBashResult`, keeping the stream
/// open until the process finishes. This means the mux stream lifetime equals
/// the bash process lifetime — the same as the v2 design, but using the new
/// `RunnerCommands` interface.
public enum MuxRunnerCommandsServer {
  /// Run the handler loop: accept inbound streams and dispatch them.
  /// Returns when the session closes or is cancelled.
  public static func serve(session: MuxSession, runner: any RunnerCommands, name: String) async {
    for await stream in session.inbound {
      let runner = runner
      let name = name
      Task {
        await handleStream(stream, runner: runner, name: name)
      }
    }
  }

  // MARK: - Stream dispatch

  private static func handleStream(_ stream: MuxStream, runner: any RunnerCommands, name: String) async {
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

      case .bash:
        let req = try MuxRunnerCodec.decode(BashRequest.self, from: payload)
        let tag = req.tag ?? UUID().uuidString
        let started = try await runner.startBash(tag: tag, command: req.command, cwd: req.cwd, timeout: req.timeout)
        let result = try await runner.waitForBashResult(tag: started.tag)
        try await MuxRunnerCodec.writeSuccess(stream, op: .bash, payload: result)

      case .cancel:
        let req = try MuxRunnerCodec.decode(CancelRequest.self, from: payload)
        let cancelResult = try await runner.cancelBash(tag: req.tag)
        let resp = CancelResponse(cancelled: cancelResult.cancelled)
        try await MuxRunnerCodec.writeSuccess(stream, op: .cancel, payload: resp)

      case .read:
        let req = try MuxRunnerCodec.decode(ReadRequest.self, from: payload)
        if req.binary {
          let data = try await runner.readData(path: req.path)
          let resp = ReadResponse(size: data.count)
          try await MuxRunnerCodec.writeSuccess(stream, op: .read, payload: resp)
          try await MuxRunnerCodec.writeBinary(stream, data: data)
        } else {
          let content = try await runner.readString(path: req.path, encoding: .utf8)
          let resp = ReadResponse(content: content, size: content.utf8.count)
          try await MuxRunnerCodec.writeSuccess(stream, op: .read, payload: resp)
        }

      case .write:
        let req = try MuxRunnerCodec.decode(WriteRequest.self, from: payload)
        if let content = req.content {
          try await runner.writeString(path: req.path, content: content, createIntermediateDirectories: req.createDirs, encoding: .utf8)
          try await MuxRunnerCodec.writeSuccess(stream, op: .write, payload: WriteResponse(bytesWritten: content.utf8.count))
        } else {
          let data = try await MuxRunnerCodec.readBinary(reader)
          try await runner.writeData(path: req.path, data: data, createIntermediateDirectories: req.createDirs)
          try await MuxRunnerCodec.writeSuccess(stream, op: .write, payload: WriteResponse(bytesWritten: data.count))
        }

      case .exists:
        let req = try MuxRunnerCodec.decode(ExistsRequest.self, from: payload)
        let existence = try await runner.exists(path: req.path)
        try await MuxRunnerCodec.writeSuccess(stream, op: .exists, payload: ExistsResponse(existence: existence))

      case .ls:
        let req = try MuxRunnerCodec.decode(LsRequest.self, from: payload)
        let entries = try await runner.listDirectory(path: req.path)
        try await MuxRunnerCodec.writeSuccess(stream, op: .ls, payload: LsResponse(entries: entries))

      case .enumerate:
        let req = try MuxRunnerCodec.decode(EnumerateRequest.self, from: payload)
        let entries = try await runner.enumerateDirectory(root: req.root)
        try await MuxRunnerCodec.writeSuccess(stream, op: .enumerate, payload: EnumerateResponse(entries: entries))

      case .mkdir:
        let req = try MuxRunnerCodec.decode(MkdirRequest.self, from: payload)
        try await runner.createDirectory(path: req.path, withIntermediateDirectories: req.recursive)
        try await MuxRunnerCodec.writeSuccess(stream, op: .mkdir, payload: MkdirResponse())

      case .find:
        let req = try MuxRunnerCodec.decode(FindParams.self, from: payload)
        let result = try await runner.find(params: req)
        try await MuxRunnerCodec.writeSuccess(stream, op: .find, payload: result)

      case .grep:
        let req = try MuxRunnerCodec.decode(GrepParams.self, from: payload)
        let result = try await runner.grep(params: req)
        try await MuxRunnerCodec.writeSuccess(stream, op: .grep, payload: result)

      case .materialize:
        let req = try MuxRunnerCodec.decode(MaterializeRequest.self, from: payload)
        let result = try await runner.materialize(params: req)
        try await MuxRunnerCodec.writeSuccess(stream, op: .materialize, payload: result)
      }

      try await stream.finish()
    } catch {
      // Best effort — stream may already be closed
      try? await stream.reset()
    }
  }
}
