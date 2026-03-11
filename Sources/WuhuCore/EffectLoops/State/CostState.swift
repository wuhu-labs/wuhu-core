/// Cost tracking — budget limit for the session.
///
/// All monetary values are in **hundredths-of-a-cent** (Int64).
/// Spending is derived from transcript entries (see `AgentState.totalSpent`).
struct CostState: Sendable, Equatable {
  var budgetLimit: Int64?

  static var empty: CostState {
    .init(budgetLimit: nil)
  }
}
