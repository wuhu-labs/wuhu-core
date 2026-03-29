public enum LsTool: FoundationToolProtocol {
  public static var toolName: String {
    "ls"
  }

  public struct Arguments: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
  }

  public typealias Result = String

  public static func execute(arguments: Arguments, context: FoundationToolContext) throws -> ToolExecution {
    let runnerID = try context.resolveRunnerID(mount: arguments.mount, runner: arguments.runner, state: context.state)
    return { _ in
      let runner = try await context.resolveRunner(id: runnerID)
      return try await runner.handleLs(arguments.path)
    }
  }
}
