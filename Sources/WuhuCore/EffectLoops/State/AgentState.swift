/// Full in-memory state for the EffectLoops-based agent loop.
///
/// Composed of sub-states, each owning a logical concern.
/// Maps from the old `WuhuSessionLoopState` — same data, restructured.
struct AgentState: Sendable, Equatable {
  var transcript: TranscriptState
  var queue: QueueState
  var inference: InferenceState
  var tools: ToolsState
  var cost: CostState
  var settings: SettingsState
  var status: StatusState

  /// Total cost derived from assistant message usage in the transcript.
  var totalSpent: Int64 {
    PricingTable.computeCost(entries: transcript.entries)
  }

  /// Whether spending has exceeded the budget limit.
  var isOverBudget: Bool {
    guard let limit = cost.budgetLimit else { return false }
    return totalSpent >= limit
  }

  static var empty: AgentState {
    .init(
      transcript: .empty,
      queue: .empty,
      inference: .empty,
      tools: .empty,
      cost: .empty,
      settings: .empty,
      status: .empty,
    )
  }
}
