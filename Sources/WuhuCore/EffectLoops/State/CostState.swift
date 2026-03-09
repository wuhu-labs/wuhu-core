/// Cost tracking — budget limits and pause gating.
///
/// All monetary values are in **hundredths-of-a-cent** (Int64).
/// When `isPaused` is true, `nextEffect` returns nil (loop idles
/// until `.cost(.approved)` or `.cost(.limitUpdated)` is sent).
struct CostState: Sendable, Equatable {
  var budgetRemaining: Int64?
  var totalSpent: Int64
  var isPaused: Bool
  var exceededEntryEmitted: Bool

  static var empty: CostState {
    .init(budgetRemaining: nil, totalSpent: 0, isPaused: false, exceededEntryEmitted: false)
  }
}
