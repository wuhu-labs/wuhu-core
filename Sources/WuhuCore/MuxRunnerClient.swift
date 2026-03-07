import Foundation
import Mux
import WuhuAPI

/// Server-side actor that implements the `Runner` protocol by forwarding
/// all calls over a `MuxSession` to a remote runner process.
///
/// Each Runner method opens a dedicated mux stream, sends the request,
/// reads the response, and returns. The stream is the correlation —
/// no request IDs, no pending maps, no continuations.
public actor MuxRunnerClient: Runner {
  public nonisolated let id: RunnerID
  public let runnerName: String
  private let session: MuxSession

  public init(name: String, session: MuxSession) {
    id = .remote(name: name)
    runnerName = name
    self.session = session
  }

  // MARK: - Runner protocol

  public func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult {
    try await rpc(.bash, request: BashRequest(command: command, cwd: cwd, timeout: timeout))
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

  /// Send a cancel request to kill a process group on the runner.
  public func cancel(processGroupID: Int32) async throws -> CancelResponse {
    try await rpc(.cancel, request: CancelRequest(processGroupID: processGroupID))
  }

  // MARK: - Generic RPC helper

  /// Open a stream, send a request, read a typed response, close.
  /// Used for simple request/response operations (no binary data).
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
