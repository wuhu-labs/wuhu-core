import Foundation
import Mux
import WuhuAPI

/// Server-side actor that implements `RunnerCommands` by forwarding
/// all calls over a `MuxSession` to a remote runner process.
///
/// Each command opens a dedicated mux stream, sends the request,
/// reads the response, and returns. The stream is the correlation —
/// no request IDs, no pending maps, no continuations.
///
/// Also starts a callback handler loop that accepts inbound mux streams
/// from the runner for `bashOutput` and `bashFinished` callbacks.
public actor MuxRunnerCommandsClient: RunnerCommands {
  public nonisolated let id: RunnerID
  public let runnerName: String
  private let session: MuxSession
  private var callbackHandler: Task<Void, Never>?

  public init(name: String, session: MuxSession) {
    id = .remote(name: name)
    runnerName = name
    self.session = session
  }

  /// Start accepting inbound callback streams from the runner.
  /// Must be called after construction to enable bash callbacks.
  public func startCallbackHandler(callbacks: any RunnerCallbacks) {
    let session = session
    callbackHandler = Task {
      for await stream in session.inbound {
        let callbacks = callbacks
        Task {
          await Self.handleCallbackStream(stream, callbacks: callbacks)
        }
      }
    }
  }

  /// Stop the callback handler.
  public func stopCallbackHandler() {
    callbackHandler?.cancel()
    callbackHandler = nil
  }

  /// Handle a single inbound callback stream from the runner.
  private static func handleCallbackStream(_ stream: MuxStream, callbacks: any RunnerCallbacks) async {
    do {
      let reader = MuxStreamReader(stream: stream)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      switch op {
      case .bashOutput:
        let cb = try MuxRunnerCodec.decode(BashOutputCallback.self, from: payload)
        try await callbacks.bashOutput(tag: cb.tag, chunk: cb.chunk)
        try await MuxRunnerCodec.writeSuccess(stream, op: .bashOutput, payload: CallbackAck())

      case .bashFinished:
        let cb = try MuxRunnerCodec.decode(BashFinishedCallback.self, from: payload)
        try await callbacks.bashFinished(tag: cb.tag, result: cb.result)
        try await MuxRunnerCodec.writeSuccess(stream, op: .bashFinished, payload: CallbackAck())

      default:
        // Unexpected op on callback channel — ignore
        try await MuxRunnerCodec.writeError(stream, op: op, message: "Unexpected op on callback channel: \(op)")
      }

      try await stream.finish()
    } catch {
      try? await stream.reset()
    }
  }

  // MARK: - RunnerCommands protocol

  public func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted {
    try await rpc(.startBash, request: StartBashRequest(tag: tag, command: command, cwd: cwd, timeout: timeout))
  }

  public func cancelBash(tag: String) async throws -> CancelResult {
    try await rpc(.cancelBash, request: CancelBashRequest(tag: tag))
  }

  public func readData(path: String) async throws -> Data {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: .read, payload: ReadRequest(path: path, binary: true))
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      throw RunnerError.requestFailed(message: String(decoding: Data(payload), as: UTF8.self))
    }
    return try await MuxRunnerCodec.readBinary(reader)
  }

  public func readString(path: String, encoding _: String.Encoding) async throws -> String {
    let resp: ReadResponse = try await rpc(.read, request: ReadRequest(path: path, binary: false))
    guard let content = resp.content else {
      throw RunnerError.requestFailed(message: "No content in text read response")
    }
    return content
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: .write, payload: WriteRequest(path: path, createDirs: createIntermediateDirectories, content: nil))
    try await MuxRunnerCodec.writeBinary(stream, data: data)
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      throw RunnerError.requestFailed(message: String(decoding: Data(payload), as: UTF8.self))
    }
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding _: String.Encoding) async throws {
    let _: WriteResponse = try await rpc(.write, request: WriteRequest(path: path, createDirs: createIntermediateDirectories, content: content))
  }

  public func exists(path: String) async throws -> FileExistence {
    let resp: ExistsResponse = try await rpc(.exists, request: ExistsRequest(path: path))
    return resp.existence
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    let resp: LsResponse = try await rpc(.ls, request: LsRequest(path: path))
    return resp.entries
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    let resp: EnumerateResponse = try await rpc(.enumerate, request: EnumerateRequest(root: root))
    return resp.entries
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    let _: MkdirResponse = try await rpc(.mkdir, request: MkdirRequest(path: path, recursive: withIntermediateDirectories))
  }

  public func find(params: FindParams) async throws -> FindResult {
    try await rpc(.find, request: params)
  }

  public func grep(params: GrepParams) async throws -> GrepResult {
    try await rpc(.grep, request: params)
  }

  public func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    try await rpc(.materialize, request: params)
  }

  // MARK: - Generic RPC helper

  /// Open a stream, send a request, read a typed response, close.
  private func rpc<Resp: Decodable>(_ op: MuxRunnerOp, request: some Encodable & Sendable) async throws -> Resp {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: op, payload: request)
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    guard ok else {
      let message = String(decoding: Data(payload), as: UTF8.self)
      throw RunnerError.requestFailed(message: message)
    }
    return try MuxRunnerCodec.decode(Resp.self, from: payload)
  }
}
