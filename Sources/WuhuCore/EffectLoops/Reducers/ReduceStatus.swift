/// Sub-reducer for status actions.
func reduceStatus(state: inout WuhuState, action: StatusAction) {
  switch action {
  case let .updated(snapshot):
    state.status.snapshot = snapshot
  }
}
