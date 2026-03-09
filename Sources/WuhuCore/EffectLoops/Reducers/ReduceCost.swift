/// Sub-reducer for cost actions.
func reduceCost(state: inout WuhuState, action: CostAction) {
  switch action {
  case let .spent(amount):
    state.cost.totalSpent += amount
    if let budget = state.cost.budgetRemaining {
      state.cost.budgetRemaining = budget - amount
      if budget - amount <= 0 {
        state.cost.isPaused = true
      }
    }

  case let .approved(amount):
    state.cost.budgetRemaining = (state.cost.budgetRemaining ?? 0) + amount
    state.cost.isPaused = false

  case .pause:
    state.cost.isPaused = true

  case .resume:
    state.cost.isPaused = false
  }
}
