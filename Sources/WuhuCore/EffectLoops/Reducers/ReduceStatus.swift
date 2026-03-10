/// Sub-reducer for status actions.
func reduceStatus(state: inout AgentState, action: StatusAction) {
  switch action {
  case let .updated(snapshot):
    state.status.snapshot = snapshot
  }
}
