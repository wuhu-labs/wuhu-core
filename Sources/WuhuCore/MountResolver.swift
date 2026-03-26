import Foundation
import WuhuAPI

/// Result of resolving a mount for tool execution.
public struct ResolvedMount: Sendable {
  public var runner: RunnerHandle
  public var cwd: String
  public var mount: WuhuMount?

  public init(runner: RunnerHandle, cwd: String, mount: WuhuMount? = nil) {
    self.runner = runner
    self.cwd = cwd
    self.mount = mount
  }
}

/// Closure that resolves a mount name to a runner + cwd.
public typealias MountResolver = @Sendable (String?) async throws -> ResolvedMount

public enum MountResolutionError: Error, Sendable, CustomStringConvertible {
  case mountNotFound(name: String)
  case runnerUnavailable(runnerID: RunnerID)
  case noCwd

  public var description: String {
    switch self {
    case let .mountNotFound(name):
      "Mount '\(name)' not found"
    case let .runnerUnavailable(runnerID):
      "Runner '\(runnerID.displayName)' is not connected"
    case .noCwd:
      "No working directory set. Call the mount tool first."
    }
  }
}
