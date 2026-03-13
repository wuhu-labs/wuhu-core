import Foundation

/// Push-based callbacks emitted by a runner for long-lived bash processes.
///
/// `startBash`/`cancelBash` are request/response RPCs. Liveness and completion
/// are delivered back to the server through this callback channel.
public protocol RunnerCallbacks: Actor, Sendable {
  /// Periodic heartbeat for a still-running bash process.
  ///
  /// Heartbeats are live-only. They are not durably buffered and may be dropped
  /// while disconnected. The server uses them to refresh last-seen timestamps
  /// for started tool calls.
  func bashHeartbeat(tag: String) async throws

  /// Final result of a bash process. Delivered exactly once per tag.
  func bashFinished(tag: String, result: BashResult) async throws
}

// MARK: - Wire types

public struct BashStarted: Sendable, Hashable, Codable {
  public var tag: String
  public var alreadyRunning: Bool

  public init(tag: String, alreadyRunning: Bool) {
    self.tag = tag
    self.alreadyRunning = alreadyRunning
  }
}

public enum BashCancelResult: String, Sendable, Hashable, Codable {
  case cancelled
  case notFound
}

public struct BashHeartbeat: Sendable, Hashable, Codable {
  public var tag: String

  public init(tag: String) {
    self.tag = tag
  }
}

public struct BashFinished: Sendable, Hashable, Codable {
  public var tag: String
  public var result: BashResult

  public init(tag: String, result: BashResult) {
    self.tag = tag
    self.result = result
  }
}

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

public struct CancelBashRequest: Sendable, Hashable, Codable {
  public var tag: String

  public init(tag: String) {
    self.tag = tag
  }
}
