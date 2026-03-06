import Foundation

/// API response for a single runner in `GET /v1/runners`.
public struct WuhuRunnerInfo: Sendable, Hashable, Codable {
  /// Runner name (e.g. "local", "origin-runner", "macbook-pro").
  public var name: String
  /// How the runner was registered: "built-in", "declared", or "incoming".
  public var source: String
  /// Whether the runner is currently connected and available for dispatch.
  public var isConnected: Bool

  public init(name: String, source: String, isConnected: Bool) {
    self.name = name
    self.source = source
    self.isConnected = isConnected
  }
}
