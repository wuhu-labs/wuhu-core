import PiAI

/// Actions for the tools subsystem — lifecycle tracking.
enum ToolsAction: Sendable {
  case willExecute(ToolCall)
  case completed(id: String, status: ToolCallStatus, toolName: String, argsHash: Int, resultHash: Int)
  case failed(id: String, status: ToolCallStatus, toolName: String, argsHash: Int)
  /// Set a tool call status without recording repetition data (e.g., from inference registering pending calls).
  case statusSet(id: String, status: ToolCallStatus)
  case resetRepetitions
  /// A bash result was delivered for a tool call (typically after server restart recovery).
  /// The effect loop should persist this result to the transcript.
  case bashResultDelivered(toolCallID: String, result: BashResult)
}
