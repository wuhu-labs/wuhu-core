/// Full in-memory state for the EffectLoops-based agent loop.
///
/// Composed of sub-states, each owning a logical concern.
/// Maps from the old `WuhuSessionLoopState` — same data, restructured.
struct WuhuState: Sendable, Equatable {
  var transcript: TranscriptState
  var queue: QueueState
  var inference: InferenceState
  var tools: ToolsState
  var cost: CostState
  var settings: SettingsState
  var status: StatusState
}
