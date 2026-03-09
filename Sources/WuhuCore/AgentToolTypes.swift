import Foundation
import PiAI

public struct AgentToolResult: Sendable, Hashable {
  public var content: [ContentBlock]
  public var details: JSONValue

  public init(content: [ContentBlock], details: JSONValue = .object([:])) {
    self.content = content
    self.details = details
  }
}

public struct AnyAgentTool: Sendable {
  public var tool: Tool
  public var label: String
  public var truncationDirection: ToolResultTruncation.Direction

  private let _execute: @Sendable (String, JSONValue) async throws -> AgentToolResult

  public init(
    tool: Tool,
    label: String,
    truncationDirection: ToolResultTruncation.Direction = .head,
    execute: @escaping @Sendable (String, JSONValue) async throws -> AgentToolResult,
  ) {
    self.tool = tool
    self.label = label
    self.truncationDirection = truncationDirection
    _execute = execute
  }

  public func execute(toolCallId: String, args: JSONValue) async throws -> AgentToolResult {
    try await _execute(toolCallId, args)
  }
}

public extension AnyAgentTool {
  init<Parameters: Decodable & Sendable>(
    name: String,
    label: String,
    description: String,
    parametersSchema: JSONValue,
    truncationDirection: ToolResultTruncation.Direction = .head,
    execute: @escaping @Sendable (String, Parameters) async throws -> AgentToolResult,
  ) {
    let tool = Tool(name: name, description: description, parameters: parametersSchema)
    self.init(tool: tool, label: label, truncationDirection: truncationDirection) { toolCallId, args in
      let params = try decode(Parameters.self, from: args)
      return try await execute(toolCallId, params)
    }
  }
}

private func decode<T: Decodable>(_: T.Type, from value: JSONValue) throws -> T {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return try JSONDecoder().decode(T.self, from: data)
}
