/// Sub-reducer for cost actions.
func reduceCost(state: inout AgentState, action: CostAction) {
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
    state.cost.exceededEntryEmitted = false

  case let .limitUpdated(newLimit):
    state.cost.budgetRemaining = newLimit - state.cost.totalSpent
    state.cost.isPaused = (state.cost.budgetRemaining ?? 0) <= 0
    if !state.cost.isPaused {
      state.cost.exceededEntryEmitted = false
    }

  case .limitCleared:
    state.cost.budgetRemaining = nil
    state.cost.isPaused = false
    state.cost.exceededEntryEmitted = false

  case .pause:
    state.cost.isPaused = true

  case .resume:
    state.cost.isPaused = false
    state.cost.exceededEntryEmitted = false
  }
}
