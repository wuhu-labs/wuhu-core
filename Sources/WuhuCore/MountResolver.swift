import Foundation
import WuhuAPI

/// Result of resolving a mount for tool execution.
public struct ResolvedMount: Sendable {
  public var runner: any Runner
  public var cwd: String
  public var mount: WuhuMount?

  public init(runner: any Runner, cwd: String, mount: WuhuMount? = nil) {
    self.runner = runner
    self.cwd = cwd
    self.mount = mount
  }
}

/// Closure that resolves a mount name to a runner + cwd.
///
/// - Parameter mountName: Optional mount name. Nil means use the primary mount.
/// - Returns: The resolved runner and working directory.
public typealias MountResolver = @Sendable (String?) async throws -> ResolvedMount

/// Builds a `MountResolver` from a session's store, runner registry, and session ID.
public enum MountResolverFactory {
  public static func make(
    sessionID: String,
    store: SQLiteSessionStore,
    runnerRegistry: RunnerRegistry,
  ) -> MountResolver {
    { mountName in
      if let mountName, !mountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Named mount
        guard let mount = try await store.getMountByName(sessionID: sessionID, name: mountName) else {
          throw MountResolutionError.mountNotFound(name: mountName)
        }
        guard let runner = await runnerRegistry.get(mount.runnerID) else {
          throw MountResolutionError.runnerUnavailable(runnerID: mount.runnerID)
        }
        return ResolvedMount(runner: runner, cwd: mount.path, mount: mount)
      } else {
        // Primary mount (or session cwd)
        if let mount = try await store.getPrimaryMount(sessionID: sessionID) {
          guard let runner = await runnerRegistry.get(mount.runnerID) else {
            throw MountResolutionError.runnerUnavailable(runnerID: mount.runnerID)
          }
          return ResolvedMount(runner: runner, cwd: mount.path, mount: mount)
        }
        // Fallback: session cwd (or "/" if no cwd) with local runner.
        // Tools that require a real working directory (e.g. bash) gate on
        // mount being nil. File tools with absolute paths work fine with "/".
        let session = try await store.getSession(id: sessionID)
        let cwd = session.cwd ?? "/"
        guard let runner = await runnerRegistry.get(.local) else {
          throw MountResolutionError.runnerUnavailable(runnerID: .local)
        }
        return ResolvedMount(runner: runner, cwd: cwd)
      }
    }
  }
}

public enum MountResolutionError: Error, Sendable, CustomStringConvertible {
  case mountNotFound(name: String)
  case runnerUnavailable(runnerID: RunnerID)

  public var description: String {
    switch self {
    case let .mountNotFound(name):
      "Mount '\(name)' not found"
    case let .runnerUnavailable(runnerID):
      "Runner '\(runnerID.displayName)' is not connected"
    }
  }
}
