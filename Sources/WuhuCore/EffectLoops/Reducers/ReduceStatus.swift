/// Sub-reducer for status actions.
func reduceStatus(state: inout AgentState, action: StatusAction) {
  switch action {
  case .stop:
    state.status.snapshot.status = .stopped
  }
}
