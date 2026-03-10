/// Sub-reducer for tools actions.
func reduceTools(state: inout AgentState, action: ToolsAction) {
  switch action {
  case let .willExecute(call):
    state.tools.statuses[call.id] = ToolCallRecord(status: .started)
    state.tools.executingIDs.insert(call.id)

  case let .completed(id, status, toolName, argsHash, resultHash):
    state.tools.statuses[id] = ToolCallRecord(status: status)
    state.tools.repetitionTracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    state.tools.recoveringIDs.remove(id)
    state.tools.executingIDs.remove(id)

  case let .failed(id, status, toolName, argsHash):
    state.tools.statuses[id] = ToolCallRecord(status: status)
    // Record failure as a repetition with a sentinel hash to distinguish from success.
    state.tools.repetitionTracker.record(toolName: toolName, argsHash: argsHash, resultHash: Int.min)
    state.tools.recoveringIDs.remove(id)
    state.tools.executingIDs.remove(id)

  case let .statusSet(id, status):
    state.tools.statuses[id] = ToolCallRecord(status: status)
    if status == .started {
      // Used by fire-and-forget tools (e.g. bash) to clear the executing guard.
      state.tools.executingIDs.remove(id)
    }

  case .resetRepetitions:
    state.tools.repetitionTracker.reset()

  case let .bashResultDelivered(toolCallID, result):
    // Store the pending result for the effect to persist.
    // The recoveringIDs guard prevents duplicate handling.
    state.tools.pendingBashResults[toolCallID] = result
    state.tools.recoveringIDs.insert(toolCallID)
  }
}
