import Foundation

// MARK: - RunnerCallbacks protocol

/// Protocol for receiving push-based bash results from a runner.
///
/// In the v3 protocol, bash execution is fire-and-forget:
/// - The server calls `startBash(tag:...)` which returns immediately
/// - The runner pushes output chunks and the final result via this protocol
///
/// `BashTagCoordinator` implements this on the server side to bridge
/// the async gap between `startBash` and the tool awaiting the result.
///
/// `MuxCallbackSender` implements this on the runner side to push
/// callbacks over mux streams back to the server.
public protocol RunnerCallbacks: Actor, Sendable {
  /// Incremental output chunk from a running bash process.
  /// Serves as both data delivery and liveness heartbeat.
  func bashOutput(tag: String, chunk: String) async throws

  /// Final result of a bash process. Delivered exactly once per tag.
  func bashFinished(tag: String, result: BashResult) async throws
}

// MARK: - Wire types for v3 bash protocol

/// Response to a `startBash` RPC.
public struct BashStarted: Sendable, Hashable, Codable {
  /// The tag echoed back for correlation.
  public var tag: String
  /// True if a bash process for this tag was already running (idempotent).
  public var alreadyRunning: Bool

  public init(tag: String, alreadyRunning: Bool) {
    self.tag = tag
    self.alreadyRunning = alreadyRunning
  }
}

/// Result of a `cancelBash` RPC.
public enum BashCancelResult: String, Sendable, Hashable, Codable {
  /// The process was found and cancellation was initiated.
  case cancelled
  /// No process with this tag was found (already finished or never started).
  case notFound
}

/// A chunk of output from a running bash process, pushed via callback.
public struct BashOutputChunk: Sendable, Hashable, Codable {
  public var tag: String
  public var chunk: String

  public init(tag: String, chunk: String) {
    self.tag = tag
    self.chunk = chunk
  }
}

/// Final result pushed via callback when a bash process completes.
public struct BashFinished: Sendable, Hashable, Codable {
  public var tag: String
  public var result: BashResult

  public init(tag: String, result: BashResult) {
    self.tag = tag
    self.result = result
  }
}

// MARK: - RPC request types

/// Request payload for `startBash` RPC.
public struct StartBashRequest: Sendable, Hashable, Codable {
  public var tag: String
  public var command: String
  public var cwd: String
  public var timeout: Double?

  public init(tag: String, command: String, cwd: String, timeout: Double? = nil) {
    self.tag = tag
    self.command = command
    self.cwd = cwd
    self.timeout = timeout
  }
}

/// Request payload for `cancelBash` RPC.
public struct CancelBashRequest: Sendable, Hashable, Codable {
  public var tag: String

  public init(tag: String) {
    self.tag = tag
  }
}

// MARK: - Callback message (for mux inbound dispatch)

/// Discriminated union for callback messages received on inbound mux streams.
public enum RunnerCallbackMessage: Sendable {
  case bashOutput(BashOutputChunk)
  case bashFinished(BashFinished)
}
