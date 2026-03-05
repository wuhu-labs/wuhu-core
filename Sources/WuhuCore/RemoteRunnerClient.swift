import Foundation
import WuhuAPI

/// Server-side actor that implements the `Runner` protocol by forwarding
/// all calls over a `RunnerConnection` (WebSocket) to a remote runner process.
public actor RemoteRunnerClient: Runner {
  public nonisolated let id: RunnerID
  private let connection: RunnerConnection
  public let runnerName: String

  public init(name: String, connection: RunnerConnection) {
    id = .remote(name: name)
    runnerName = name
    self.connection = connection
  }

  // MARK: - Runner protocol

  public func runBash(command: String, cwd: String, timeout: TimeInterval?) async throws -> BashResult {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(
      .bash(id: rid, BashRequest(command: command, cwd: cwd, timeout: timeout)),
      requestID: rid,
    )
    guard case let .bash(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(v): return v
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func readData(path: String) async throws -> Data {
    let rid = Self.makeID()
    let (response, binaryData) = try await connection.request(
      .read(id: rid, ReadRequest(path: path, binary: true)),
      requestID: rid,
    )
    guard case let .read(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case .success:
      guard let data = binaryData else {
        throw RunnerError.requestFailed(message: "Expected binary frame for readData")
      }
      return data
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func readString(path: String, encoding _: String.Encoding) async throws -> String {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(
      .read(id: rid, ReadRequest(path: path, binary: false)),
      requestID: rid,
    )
    guard case let .read(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r):
      guard let content = r.content else {
        throw RunnerError.requestFailed(message: "No content in text read response")
      }
      return content
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    let rid = Self.makeID()
    // Send text frame (write request with no content) + binary frame (the data)
    let (response, _) = try await connection.requestWithBinary(
      .write(id: rid, WriteRequest(path: path, createDirs: createIntermediateDirectories, content: nil)),
      requestID: rid,
      binaryData: data,
    )
    guard case let .write(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if case let .failure(e) = result { throw RunnerError.requestFailed(message: e.message) }
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding _: String.Encoding) async throws {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(
      .write(id: rid, WriteRequest(path: path, createDirs: createIntermediateDirectories, content: content)),
      requestID: rid,
    )
    guard case let .write(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if case let .failure(e) = result { throw RunnerError.requestFailed(message: e.message) }
  }

  public func exists(path: String) async throws -> FileExistence {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.exists(id: rid, ExistsRequest(path: path)), requestID: rid)
    guard case let .exists(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r.existence
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.ls(id: rid, LsRequest(path: path)), requestID: rid)
    guard case let .ls(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r.entries
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.enumerate(id: rid, EnumerateRequest(root: root)), requestID: rid)
    guard case let .enumerate(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r.entries
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.mkdir(id: rid, MkdirRequest(path: path, recursive: withIntermediateDirectories)), requestID: rid)
    guard case let .mkdir(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if case let .failure(e) = result { throw RunnerError.requestFailed(message: e.message) }
  }

  public func find(params: FindParams) async throws -> FindResult {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.find(id: rid, params), requestID: rid)
    guard case let .find(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func grep(params: GrepParams) async throws -> GrepResult {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.grep(id: rid, params), requestID: rid)
    guard case let .grep(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  public func materialize(params: MaterializeRequest) async throws -> MaterializeResponse {
    let rid = Self.makeID()
    let (response, _) = try await connection.request(.materialize(id: rid, params), requestID: rid)
    guard case let .materialize(_, result) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    switch result {
    case let .success(r): return r
    case let .failure(e): throw RunnerError.requestFailed(message: e.message)
    }
  }

  private static func makeID() -> String {
    UUID().uuidString.lowercased()
  }
}

// MARK: - RunnerConnection

/// Manages a WebSocket connection to a runner, handling request/response correlation.
/// Supports both text frames (JSON) and binary frames (raw data with UUID prefix).
public actor RunnerConnection {
  public let runnerName: String

  private struct PendingRequest {
    var continuation: CheckedContinuation<(RunnerResponse, Data?), any Error>
    /// Binary data received before the text response (for read responses).
    var binaryData: Data?
    /// Whether we've received the text response but are waiting for binary data.
    var textResponse: RunnerResponse?
  }

  private var pending: [String: PendingRequest] = [:]
  private var isClosed: Bool = false

  /// Closure to send a text message over WebSocket.
  private var sendText: @Sendable (String) async throws -> Void
  /// Closure to send a binary message over WebSocket.
  private var sendBinary: @Sendable (Data) async throws -> Void

  public init(
    runnerName: String,
    sendText: @Sendable @escaping (String) async throws -> Void = { _ in },
    sendBinary: @Sendable @escaping (Data) async throws -> Void = { _ in },
  ) {
    self.runnerName = runnerName
    self.sendText = sendText
    self.sendBinary = sendBinary
  }

  public func setSend(
    text: @Sendable @escaping (String) async throws -> Void,
    binary: @Sendable @escaping (Data) async throws -> Void,
  ) {
    sendText = text
    sendBinary = binary
  }

  /// Send a text-only request and wait for response.
  public func request(_ request: RunnerRequest, requestID: String) async throws -> (RunnerResponse, Data?) {
    guard !isClosed else { throw RunnerError.disconnected(runnerName: runnerName) }

    return try await withCheckedThrowingContinuation { continuation in
      pending[requestID] = PendingRequest(continuation: continuation)
      Task {
        do {
          let data = try JSONEncoder().encode(request)
          try await self.sendText(String(decoding: data, as: UTF8.self))
        } catch {
          if let p = self.pending.removeValue(forKey: requestID) {
            p.continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Send a text request followed by a binary frame, then wait for response.
  public func requestWithBinary(_ request: RunnerRequest, requestID: String, binaryData: Data) async throws -> (RunnerResponse, Data?) {
    guard !isClosed else { throw RunnerError.disconnected(runnerName: runnerName) }

    return try await withCheckedThrowingContinuation { continuation in
      pending[requestID] = PendingRequest(continuation: continuation)
      Task {
        do {
          let jsonData = try JSONEncoder().encode(request)
          try await self.sendText(String(decoding: jsonData, as: UTF8.self))
          let frame = RunnerBinaryFrame.encode(id: requestID, data: binaryData)
          try await self.sendBinary(frame)
        } catch {
          if let p = self.pending.removeValue(forKey: requestID) {
            p.continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Handle an incoming text-frame response.
  public func handleResponse(_ response: RunnerResponse) {
    guard let id = response.responseID else { return }
    guard var p = pending.removeValue(forKey: id) else { return }

    // Check if this response expects companion binary data
    let needsBinary = if case let .read(_, result) = response {
      switch result {
      case let .success(readResp) where readResp.content == nil:
        true
      default:
        false
      }
    } else {
      false
    }

    if needsBinary {
      // Binary read — need companion binary frame
      if let binaryData = p.binaryData {
        // Binary data already arrived
        p.continuation.resume(returning: (response, binaryData))
      } else {
        // Wait for binary frame
        p.textResponse = response
        pending[id] = p
      }
      return
    }

    p.continuation.resume(returning: (response, nil))
  }

  /// Handle an incoming binary frame.
  public func handleBinaryFrame(_ frameData: Data) {
    guard let (id, payload) = RunnerBinaryFrame.decode(frameData) else { return }
    guard var p = pending.removeValue(forKey: id) else { return }

    if let textResponse = p.textResponse {
      // Text response already arrived — complete the request
      p.continuation.resume(returning: (textResponse, payload))
    } else {
      // Text response not yet arrived — stash the binary data
      p.binaryData = payload
      pending[id] = p
    }
  }

  public func close() {
    guard !isClosed else { return }
    isClosed = true
    let error = RunnerError.disconnected(runnerName: runnerName)
    for (_, p) in pending {
      p.continuation.resume(throwing: error)
    }
    pending.removeAll()
  }

  public var closed: Bool {
    isClosed
  }
}
