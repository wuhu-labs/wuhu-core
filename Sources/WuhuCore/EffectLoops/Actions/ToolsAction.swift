import PiAI

/// Actions for the tools subsystem — lifecycle tracking.
enum ToolsAction: Sendable {
  case willExecute(ToolCall)
  case completed(id: String, status: ToolCallStatus, toolName: String, argsHash: Int, resultHash: Int)
  case failed(id: String, status: ToolCallStatus, toolName: String, argsHash: Int)
  /// Set a tool call status without recording repetition data (e.g., from inference registering pending calls).
  case statusSet(id: String, status: ToolCallStatus)
  case resetRepetitions
}
