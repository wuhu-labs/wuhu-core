public enum ParkTool: FoundationToolProtocol {
  public static var toolName: String {
    "park"
  }

  public struct Arguments: Equatable, Codable, Sendable {
    public var reason: String?
    public var timeout: Int?
  }

  public typealias Result = String

  public static func execute(arguments: Arguments, context _: FoundationToolContext) throws -> ToolExecution {
    { _ in
      arguments.reason ?? ""
    }
  }
}
