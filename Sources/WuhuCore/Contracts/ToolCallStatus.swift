/// Status of a tool call in the execution lifecycle.
public enum ToolCallStatus: String, Sendable, Hashable, Codable {
  case pending
  case started
  case completed
  case errored
}
