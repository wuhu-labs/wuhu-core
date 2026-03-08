import PiAI

/// Actions for the tools subsystem — lifecycle tracking.
enum ToolsAction: Sendable {
  case willExecute(ToolCall)
  case completed(id: String, status: ToolCallStatus)
  case failed(id: String, status: ToolCallStatus)
  case resetRepetitions
}
