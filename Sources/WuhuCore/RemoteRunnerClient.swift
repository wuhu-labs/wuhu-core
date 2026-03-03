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
    let response = try await connection.request(
      RunnerRequest.bash(id: rid, command: command, cwd: cwd, timeout: timeout),
      requestID: rid,
    )
    guard case let .bash(_, result, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let result else { throw RunnerError.requestFailed(message: "No bash result") }
    return result
  }

  public func readData(path: String) async throws -> Data {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.readFile(id: rid, path: path),
      requestID: rid,
    )
    guard case let .readFile(_, base64Data, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let base64Data, let data = Data(base64Encoded: base64Data) else {
      throw RunnerError.requestFailed(message: "No data in response or invalid base64")
    }
    return data
  }

  public func readString(path: String, encoding: String.Encoding) async throws -> String {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.readString(id: rid, path: path),
      requestID: rid,
    )
    guard case let .readString(_, content, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let content else { throw RunnerError.requestFailed(message: "No content in response") }
    return content
  }

  public func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.writeFile(id: rid, path: path, base64Data: data.base64EncodedString(), createDirs: createIntermediateDirectories),
      requestID: rid,
    )
    guard case let .writeFile(_, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
  }

  public func writeString(path: String, content: String, createIntermediateDirectories: Bool, encoding: String.Encoding) async throws {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.writeString(id: rid, path: path, content: content, createDirs: createIntermediateDirectories),
      requestID: rid,
    )
    guard case let .writeString(_, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
  }

  public func exists(path: String) async throws -> FileExistence {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.exists(id: rid, path: path),
      requestID: rid,
    )
    guard case let .exists(_, existence, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let existence else { throw RunnerError.requestFailed(message: "No existence result") }
    return existence
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.listDirectory(id: rid, path: path),
      requestID: rid,
    )
    guard case let .listDirectory(_, entries, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let entries else { throw RunnerError.requestFailed(message: "No entries in response") }
    return entries
  }

  public func enumerateDirectory(root: String) async throws -> [EnumeratedEntry] {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.enumerateDirectory(id: rid, root: root),
      requestID: rid,
    )
    guard case let .enumerateDirectory(_, entries, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
    guard let entries else { throw RunnerError.requestFailed(message: "No entries in response") }
    return entries
  }

  public func createDirectory(path: String, withIntermediateDirectories: Bool) async throws {
    let rid = Self.makeID()
    let response = try await connection.request(
      RunnerRequest.createDirectory(id: rid, path: path, withIntermediateDirectories: withIntermediateDirectories),
      requestID: rid,
    )
    guard case let .createDirectory(_, error) = response else {
      throw RunnerError.requestFailed(message: "Unexpected response type")
    }
    if let error { throw RunnerError.requestFailed(message: error) }
  }

  private static func makeID() -> String {
    UUID().uuidString.lowercased()
  }
}

// MARK: - RunnerConnection

/// Manages a WebSocket connection to a runner, handling request/response correlation.
/// Used by `RemoteRunnerClient` on the server side.
public actor RunnerConnection {
  public let runnerName: String
  private var pending: [String: CheckedContinuation<RunnerResponse, any Error>] = [:]
  private var isClosed: Bool = false

  /// Closure to send a serialized request message over WebSocket.
  private var sendMessage: @Sendable (String) async throws -> Void

  /// Create with a send closure. Use `init(runnerName:)` + `setSendMessage(_:)` for
  /// cases where the closure needs to capture the connection itself (in-process loopback).
  public init(runnerName: String, sendMessage: @Sendable @escaping (String) async throws -> Void) {
    self.runnerName = runnerName
    self.sendMessage = sendMessage
  }

  /// Create without a send closure. Must call `setSendMessage(_:)` before first request.
  public init(runnerName: String) {
    self.runnerName = runnerName
    sendMessage = { _ in throw RunnerError.disconnected(runnerName: runnerName) }
  }

  /// Set the send closure after initialization. Enables loopback patterns where
  /// the closure needs to capture the connection.
  public func setSendMessage(_ send: @Sendable @escaping (String) async throws -> Void) {
    sendMessage = send
  }

  /// Send a request and wait for the correlated response.
  public func request(_ request: RunnerRequest, requestID: String) async throws -> RunnerResponse {
    guard !isClosed else {
      throw RunnerError.disconnected(runnerName: runnerName)
    }

    return try await withCheckedThrowingContinuation { continuation in
      pending[requestID] = continuation
      Task {
        do {
          let data = try JSONEncoder().encode(request)
          let text = String(decoding: data, as: UTF8.self)
          try await self.sendMessage(text)
        } catch {
          if let cont = self.removePending(requestID) {
            cont.resume(throwing: error)
          }
        }
      }
    }
  }

  /// Called when a response message arrives from the WebSocket.
  public func handleResponse(_ response: RunnerResponse) {
    guard let id = response.responseID else { return }
    if let cont = pending.removeValue(forKey: id) {
      cont.resume(returning: response)
    }
  }

  /// Mark the connection as closed and fail all pending requests.
  public func close() {
    guard !isClosed else { return }
    isClosed = true
    let error = RunnerError.disconnected(runnerName: runnerName)
    for (_, cont) in pending {
      cont.resume(throwing: error)
    }
    pending.removeAll()
  }

  /// Whether the connection has been closed.
  public var closed: Bool { isClosed }

  private func removePending(_ id: String) -> CheckedContinuation<RunnerResponse, any Error>? {
    pending.removeValue(forKey: id)
  }
}
