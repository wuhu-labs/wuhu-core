import Foundation
import Logging
import Mux
import WuhuAPI

private let logger = WuhuDebugLogger.logger("MuxRunnerClient")

/// Server-side actor that implements the `Runner` protocol by forwarding
/// all calls over a `MuxSession` to a remote runner process.
///
/// Each Runner method opens a dedicated mux stream, sends the request,
/// reads the response, and returns. The stream is the correlation —
/// no request IDs, no pending maps, no continuations.
///
/// ## v3 protocol
///
/// Bash uses short-lived `startBash`/`cancelBash` RPCs. Results arrive
/// asynchronously via inbound callback streams (bashOutput, bashFinished)
/// which are dispatched to the `RunnerCallbacks` target.
public actor MuxRunnerClient: Runner {
  public nonisolated let id: RunnerID
  public let runnerName: String
  private let session: MuxSession

  /// Callbacks target for dispatching inbound bash callbacks.
  private var callbacks: (any RunnerCallbacks)?

  public init(name: String, session: MuxSession) {
    id = .remote(name: name)
    runnerName = name
    self.session = session
  }

  // MARK: - Callbacks

  /// Set the callbacks target and start listening for inbound callback streams.
  public func setCallbacks(_ callbacks: any RunnerCallbacks) async {
    self.callbacks = callbacks
  }

  /// Start listening for inbound callback streams from the runner.
  /// Call this after `setCallbacks` and run it in a background task.
  /// Returns when the session closes.
  public func startCallbackListener() async {
    for await stream in session.inbound {
      let callbacks = callbacks
      let runnerName = runnerName
      Task {
        await Self.handleCallbackStream(stream, callbacks: callbacks, runnerName: runnerName)
      }
    }
  }

  private static func handleCallbackStream(_ stream: MuxStream, callbacks: (any RunnerCallbacks)?, runnerName: String) async {
    do {
      let reader = MuxStreamReader(stream: stream)
      let (op, payload) = try await MuxRunnerCodec.readRequest(reader)

      switch op {
      case .bashOutput:
        let chunk = try MuxRunnerCodec.decode(BashOutputChunk.self, from: payload)
        logger.debug(
          "server received bashOutput callback",
          metadata: [
            "tag": "\(chunk.tag)",
            "runner": "\(runnerName)",
            "chunkSize": "\(chunk.chunk.count)",
          ],
        )
        try await callbacks?.bashOutput(tag: chunk.tag, chunk: chunk.chunk)
        // Send ack
        try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: EmptyAck())

      case .bashFinished:
        let finished = try MuxRunnerCodec.decode(BashFinished.self, from: payload)
        logger.debug(
          "server received bashFinished callback",
          metadata: [
            "tag": "\(finished.tag)",
            "runner": "\(runnerName)",
            "exitCode": "\(finished.result.exitCode)",
            "timedOut": "\(finished.result.timedOut)",
            "terminated": "\(finished.result.terminated)",
            "outputSize": "\(finished.result.output.count)",
          ],
        )
        try await callbacks?.bashFinished(tag: finished.tag, result: finished.result)
        // Send ack
        try await MuxRunnerCodec.writeSuccess(stream, op: op, payload: EmptyAck())

      default:
        // Unexpected op on callback stream
        try await MuxRunnerCodec.writeError(stream, op: op, message: "Unexpected op \(op) on callback stream")
      }

      try await stream.finish()
    } catch {
      try? await stream.reset()
    }
  }

  // MARK: - Runner protocol (v3: short-lived RPCs)

  public func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted {
    let commandPreview = String(command.prefix(50))
    logger.debug(
      "server sending startBash to runner",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
        "cwd": "\(cwd)",
        "timeout": "\(timeout.map { String($0) } ?? "none")",
        "commandPreview": "\(commandPreview)",
      ],
    )

    let result: BashStarted = try await rpc(.startBash, request: StartBashRequest(tag: tag, command: command, cwd: cwd, timeout: timeout))

    logger.debug(
      "server received startBash response from runner",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
        "alreadyRunning": "\(result.alreadyRunning)",
      ],
    )

    return result
  }

  public func cancelBash(tag: String) async throws -> BashCancelResult {
    logger.debug(
      "server sending cancelBash to runner",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
      ],
    )

    let result: BashCancelResult = try await rpc(.cancelBash, request: CancelBashRequest(tag: tag))

    logger.debug(
      "server received cancelBash response from runner",
      metadata: [
        "tag": "\(tag)",
        "runner": "\(runnerName)",
        "result": "\(result.rawValue)",
      ],
    )

    return result
  }

  // MARK: - File I/O

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

// MARK: - EmptyAck

/// Empty acknowledgement for callback streams.
private struct EmptyAck: Codable, Sendable {}
