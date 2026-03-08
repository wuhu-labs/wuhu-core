/// Sub-reducer for tools actions.
func reduceTools(state: inout WuhuState, action: ToolsAction) {
  switch action {
  case let .willExecute(call):
    state.tools.statuses[call.id] = .started

  case let .completed(id, status):
    state.tools.statuses[id] = status

  case let .failed(id, status):
    state.tools.statuses[id] = status

  case .resetRepetitions:
    state.tools.repetitionTracker.reset()
  }
}
