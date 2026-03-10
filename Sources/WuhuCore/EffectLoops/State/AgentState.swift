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
