import Foundation
import WuhuAPI

/// Information about a registered runner.
public struct RunnerInfo: Sendable, Hashable {
  public enum Source: String, Sendable, Hashable {
    /// Built-in local runner.
    case builtIn = "built-in"
    /// Declared in server config.
    case declared
  }

  public var name: String
  public var source: Source
  public var isConnected: Bool

  public init(name: String, source: Source, isConnected: Bool) {
    self.name = name
    self.source = source
    self.isConnected = isConnected
  }
}

/// Server-side registry of available runners.
/// Always contains a local runner. Remote runners declared in server config
/// are registered as client-backed implementations of `Runner`.
public actor RunnerRegistry {
  private var runners: [String: any Runner] = [:]
  /// Names declared in server config. These always appear in `listAll`,
  /// even when disconnected.
  private var declaredNames: Set<String> = []

  public init() {
    let local = LocalRunner()
    runners["local"] = local
  }

  /// Record the set of runner names declared in server config.
  /// Called once at server startup.
  public func declareConfigured(_ names: [String]) {
    for name in names {
      declaredNames.insert(name)
    }
  }

  /// Register a runner. For local, uses key "local".
  /// For remote, uses the runner name.
  public func register(_ runner: any Runner) {
    let key = runnerKey(runner.id)
    runners[key] = runner
  }

  /// Remove a runner by its ID.
  public func remove(_ id: RunnerID) {
    let key = runnerKey(id)
    // Never remove the local runner
    guard key != "local" else { return }
    runners.removeValue(forKey: key)
  }

  /// Get a runner by its RunnerID.
  public func get(_ id: RunnerID) -> (any Runner)? {
    runners[runnerKey(id)]
  }

  /// Get a runner by name. "local" returns the local runner.
  public func get(name: String) -> (any Runner)? {
    if name == "local" { return runners["local"] }
    return runners[name]
  }

  /// List all registered runner names.
  public func listRunnerNames() -> [String] {
    runners.keys.sorted()
  }

  /// List all runners with status information.
  /// Includes: local (always) and all declared runners.
  public func listAll() -> [RunnerInfo] {
    var result: [RunnerInfo] = []

    // Local runner — always present
    result.append(RunnerInfo(name: "local", source: .builtIn, isConnected: true))

    // Declared runners — always listed, with connection status
    for name in declaredNames.sorted() {
      result.append(RunnerInfo(
        name: name,
        source: .declared,
        isConnected: runners[name] != nil,
      ))
    }

    return result
  }

  /// Check if a runner is registered and reachable.
  public func isAvailable(_ id: RunnerID) -> Bool {
    runners[runnerKey(id)] != nil
  }

  private func runnerKey(_ id: RunnerID) -> String {
    switch id {
    case .local: "local"
    case let .remote(name): name
    }
  }
}
