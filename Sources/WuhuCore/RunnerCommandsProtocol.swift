import Foundation

// MARK: - New result types for v3 protocol

/// Returned by `startBash` to confirm the bash was registered.
public struct BashStarted: Sendable, Hashable, Codable {
  /// The tag that was registered.
  public var tag: String
  /// True if a bash with this tag was already running (idempotent start).
  public var alreadyRunning: Bool

  public init(tag: String, alreadyRunning: Bool) {
    self.tag = tag
    self.alreadyRunning = alreadyRunning
  }
}

/// Result of a `cancelBash` call.
public struct CancelResult: Sendable, Hashable, Codable {
  /// True if a running bash was found and cancelled.
  public var cancelled: Bool

  public init(cancelled: Bool) {
    self.cancelled = cancelled
  }
}

/// Acknowledgment returned by `RunnerCallbacks` methods.
public struct Ack: Sendable, Hashable, Codable {
  public init() {}
}

// MARK: - RunnerCommands

/// Commands sent TO the runner. The server (or test) holds this.
///
/// All RPCs are short-lived — they return immediately after registering
/// the operation or performing a quick I/O operation. Bash process lifetime
/// is completely decoupled from RPC lifetime.
///
/// Results from `startBash` are delivered asynchronously via `RunnerCallbacks`.
/// Call `waitForBashResult(tag:)` to await the result.
public protocol RunnerCommands: Sendable {
  /// Unique identifier for this runner instance.
  nonisolated var id: RunnerID { get }

  // MARK: - Bash

  /// Start a bash command. Returns immediately after spawning the process.
  /// Idempotent: calling twice with the same tag returns the existing state.
  func startBash(tag: String, command: String, cwd: String, timeout: TimeInterval?) async throws -> BashStarted

  /// Cancel a running bash command by tag.
  func cancelBash(tag: String) async throws -> CancelResult

  /// Wait for the result of a bash started with `startBash(tag:...)`.
  /// Suspends until the runner delivers a `bashFinished` callback for this tag.
  func waitForBashResult(tag: String) async throws -> BashResult

  // MARK: - File I/O

  func readData(path: String) async throws -> Data
  func readString(path: String, encoding: String.Encoding) async throws -> String
  func writeData(path: String, data: Data, createIntermediateDirectories: Bool) async throws
  func writeString(
    path: String, content: String, createIntermediateDirectories: Bool,
    encoding: String.Encoding,
  ) async throws
  func exists(path: String) async throws -> FileExistence
  func listDirectory(path: String) async throws -> [DirectoryEntry]
  func enumerateDirectory(root: String) async throws -> [EnumeratedEntry]
  func createDirectory(path: String, withIntermediateDirectories: Bool) async throws

  // MARK: - Search

  func find(params: FindParams) async throws -> FindResult
  func grep(params: GrepParams) async throws -> GrepResult

  // MARK: - Workspace

  func materialize(params: MaterializeRequest) async throws -> MaterializeResponse
}

// MARK: - RunnerCallbacks

/// Callbacks FROM the runner. The server (or test) holds this to receive bash results.
///
/// The runner calls these to deliver incremental output chunks and final results.
public protocol RunnerCallbacks: Sendable {
  /// Deliver an incremental output chunk from a running bash process.
  /// Serves as both data delivery and a liveness heartbeat.
  func bashOutput(tag: String, chunk: String) async throws -> Ack

  /// Deliver the final result of a completed bash process.
  func bashFinished(tag: String, result: BashResult) async throws -> Ack
}
