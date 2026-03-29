
public struct Mount: Codable, Hashable, Sendable {
  public var name: String
  public var runner: RunnerID
  public var path: String
}

public enum MountTool: FoundationToolProtocol {
  public static var toolName: String {
    "mount"
  }

  public typealias Arguments = Mount

  public struct Result: Codable, Sendable, Equatable {
    public var mount: Mount
    public var agentsMD: String?
  }

  public static func execute(arguments: Arguments, context: FoundationToolContext) throws -> ToolExecution {
    let noDuplicates = context.state.mounts.allSatisfy {
      $0.name != arguments.name
    }
    guard noDuplicates else {
      throw FoundationTool.ValidationError.duplicatedMountName(arguments.name)
    }

    return { _ in
      let runner = try await context.resolveRunner(id: arguments.runner)
      return try await runner.handleMount(arguments)
    }
  }
}
