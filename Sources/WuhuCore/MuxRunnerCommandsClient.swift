import Foundation
import Mux
import WuhuAPI

/// Server-side actor that implements `RunnerCommands` by forwarding calls over
/// a `MuxSession` to a remote runner process.
///
/// File I/O operations open a dedicated mux stream per call (same as before).
/// Bash uses a non-blocking pattern:
/// - `startBash` spawns a background Task that sends the bash RPC and feeds
///   the result into an embedded `BashCallbackBridge`.
/// - `waitForBashResult` suspends until the bridge delivers the result.
/// - `cancelBash` cancels the background Task (which triggers process teardown
///   via teardownSequence) and sends a cancel RPC to the runner.
public actor MuxRunnerCommandsClient: RunnerCommands {
  public nonisolated let id: RunnerID
  public let runnerName: String
  private let session: MuxSession
  private let callbackBridge = BashCallbackBridge()
  private var activeTasks: [String: Task<Void, Never>] = [:]

  public init(name: String, session: MuxSession) {
    id = .remote(name: name)
    runnerName = name
    self.session = session
  }

  // MARK: - Bash

  public func startBash(
    tag: String,
    command: String,
    cwd: String,
    timeout: TimeInterval?,
  ) async throws -> BashStarted {
    if activeTasks[tag] != nil {
      return BashStarted(tag: tag, alreadyRunning: true)
    }

    let bridge = callbackBridge
    let session = session
    let task = Task<Void, Never> {
      do {
        let result: BashResult = try await Self.bashRPC(
          session: session,
          command: command,
          cwd: cwd,
          timeout: timeout,
          tag: tag,
        )
        _ = try? await bridge.bashFinished(tag: tag, result: result)
      } catch is CancellationError {
        _ = try? await bridge.bashFinished(
          tag: tag,
          result: BashResult(exitCode: -15, output: "", timedOut: false, terminated: true),
        )
      } catch {
        _ = try? await bridge.bashFinished(
          tag: tag,
          result: BashResult(exitCode: -1, output: String(describing: error), timedOut: false, terminated: false),
        )
      }
      await self.bashTaskFinished(tag: tag)
    }
    activeTasks[tag] = task
    return BashStarted(tag: tag, alreadyRunning: false)
  }

  public func cancelBash(tag: String) async throws -> CancelResult {
    guard let task = activeTasks.removeValue(forKey: tag) else {
      return CancelResult(cancelled: false)
    }
    task.cancel()
    // Send cancel RPC to the remote runner so the subprocess is actually killed.
    // Propagate errors: if this throws, the caller knows the remote cancel failed.
    let _: CancelResponse = try await rpc(.cancel, request: CancelRequest(tag: tag))
    return CancelResult(cancelled: true)
  }

  private func bashTaskFinished(tag: String) {
    activeTasks.removeValue(forKey: tag)
  }

  public func waitForBashResult(tag: String) async throws -> BashResult {
    try await callbackBridge.waitForResult(tag: tag)
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

  // MARK: - Private helpers

  /// Send a bash request and wait for the result on the same stream.
  /// This runs in a background task started by `startBash`.
  private static func bashRPC(
    session: MuxSession,
    command: String,
    cwd: String,
    timeout: TimeInterval?,
    tag: String,
  ) async throws -> BashResult {
    let stream = try await session.open()
    try await MuxRunnerCodec.writeRequest(stream, op: .bash, payload: BashRequest(command: command, cwd: cwd, timeout: timeout, tag: tag))
    try await stream.finish()

    let reader = MuxStreamReader(stream: stream)
    let (ok, _, payload) = try await MuxRunnerCodec.readResponse(reader)
    if !ok {
      let message = String(decoding: Data(payload), as: UTF8.self)
      throw RunnerError.requestFailed(message: message)
    }
    return try MuxRunnerCodec.decode(BashResult.self, from: payload)
  }

  /// Generic request/response RPC helper (no binary data).
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
