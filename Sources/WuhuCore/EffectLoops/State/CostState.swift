/// Cost tracking — budget limits and pause gating.
///
/// New capability: cost gating was not tracked in the old loop.
/// When `isPaused` is true, `nextEffect` returns nil (loop idles
/// until `.cost(.approved)` is sent).
struct CostState: Sendable, Equatable {
  var budgetRemaining: Int?
  var totalSpent: Int
  var isPaused: Bool

  static var empty: CostState {
    .init(budgetRemaining: nil, totalSpent: 0, isPaused: false)
  }
}
