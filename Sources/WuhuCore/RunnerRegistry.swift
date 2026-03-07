import Foundation
import WuhuAPI

/// Information about a registered runner.
public struct RunnerInfo: Sendable, Hashable {
  public enum Source: String, Sendable, Hashable {
    /// Built-in local runner.
    case builtIn = "built-in"
    /// Declared in server config (server connects out).
    case declared
    /// Connected in via WebSocket (runner connects to server).
    case incoming
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

/// Server-side registry of live runners.
///
/// Starts empty. The local runner is registered externally by
/// `WuhuLocalRunnerSpawner` after spawning the child process.
/// Remote runners are registered/removed as connections come and go.
///
/// Tracks two categories of remote runners:
/// - **Declared** runners from server config (server connects out to them).
/// - **Incoming** runners that connect in via the server's WebSocket endpoint.
///
/// When a declared and incoming runner share the same name, the declared one
/// takes priority for dispatch.
public actor RunnerRegistry {
  private var runners: [String: any RunnerCommands] = [:]
  /// Names declared in server config. These always appear in `listAll`,
  /// even when disconnected.
  private var declaredNames: Set<String> = []
  /// Names of runners that connected in (not declared in config).
  private var incomingNames: Set<String> = []

  public init() {}

  /// Initialize with pre-registered runners (used by tests).
  public init(runners: [any RunnerCommands]) {
    for runner in runners {
      let key: String = switch runner.id {
      case .local: "local"
      case let .remote(name: n): n
      }
      self.runners[key] = runner
    }
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
  public func register(_ runner: any RunnerCommands) {
    let key = runnerKey(runner.id)
    runners[key] = runner
  }

  /// Register an incoming runner (connected via the server's WS endpoint).
  /// If a declared runner with the same name is already connected, the
  /// incoming one is rejected (returns false).
  @discardableResult
  public func registerIncoming(_ runner: any RunnerCommands, name: String) -> Bool {
    if declaredNames.contains(name), runners[name] != nil {
      // Declared runner already connected — reject incoming with same name.
      return false
    }
    runners[name] = runner
    if !declaredNames.contains(name) {
      incomingNames.insert(name)
    }
    return true
  }

  /// Remove a runner by its ID.
  public func remove(_ id: RunnerID) {
    let key = runnerKey(id)
    runners.removeValue(forKey: key)
    incomingNames.remove(key)
  }

  /// Get a runner by its RunnerID.
  public func get(_ id: RunnerID) -> (any RunnerCommands)? {
    runners[runnerKey(id)]
  }

  /// Get a runner by name. "local" returns the local runner.
  public func get(name: String) -> (any RunnerCommands)? {
    if name == "local" { return runners["local"] }
    return runners[name]
  }

  /// List all registered runner names.
  public func listRunnerNames() -> [String] {
    runners.keys.sorted()
  }

  /// List all runners with status information.
  /// Includes: local (always), all declared runners (connected or not),
  /// and all incoming runners (only while connected).
  public func listAll() -> [RunnerInfo] {
    var result: [RunnerInfo] = []

    // Local runner — present if registered
    if runners["local"] != nil {
      result.append(RunnerInfo(name: "local", source: .builtIn, isConnected: true))
    }

    // Declared runners — always listed, with connection status
    for name in declaredNames.sorted() {
      result.append(RunnerInfo(
        name: name,
        source: .declared,
        isConnected: runners[name] != nil,
      ))
    }

    // Incoming runners — only listed while connected
    for name in incomingNames.sorted() {
      if runners[name] != nil {
        result.append(RunnerInfo(
          name: name,
          source: .incoming,
          isConnected: true,
        ))
      }
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
