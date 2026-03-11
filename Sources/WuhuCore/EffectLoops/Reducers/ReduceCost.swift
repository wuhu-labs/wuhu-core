/// Sub-reducer for cost actions.
func reduceCost(state: inout AgentState, action: CostAction) {
  switch action {
  case let .limitUpdated(newLimit):
    state.cost.budgetLimit = newLimit

  case .limitCleared:
    state.cost.budgetLimit = nil
  }
}
