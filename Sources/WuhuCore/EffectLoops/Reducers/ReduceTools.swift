/// Sub-reducer for tools actions.
func reduceTools(state: inout WuhuState, action: ToolsAction) {
  switch action {
  case let .willExecute(call):
    state.tools.statuses[call.id] = .started

  case let .completed(id, status, toolName, argsHash, resultHash):
    state.tools.statuses[id] = status
    state.tools.repetitionTracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    state.tools.recoveringIDs.remove(id)
    state.tools.executingIDs.remove(id)

  case let .failed(id, status, toolName, argsHash):
    state.tools.statuses[id] = status
    // Record failure as a repetition with a sentinel hash to distinguish from success.
    state.tools.repetitionTracker.record(toolName: toolName, argsHash: argsHash, resultHash: Int.min)
    state.tools.recoveringIDs.remove(id)
    state.tools.executingIDs.remove(id)

  case let .statusSet(id, status):
    state.tools.statuses[id] = status

  case .resetRepetitions:
    state.tools.repetitionTracker.reset()
  }
}
