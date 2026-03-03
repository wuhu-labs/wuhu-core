import Foundation
import WuhuAPI

/// Server-side registry of live runners.
/// Always contains a local runner. Remote runners are registered/removed
/// as WebSocket connections come and go.
public actor RunnerRegistry {
  private var runners: [String: any Runner] = [:]

  public init() {
    let local = LocalRunner()
    runners["local"] = local
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
