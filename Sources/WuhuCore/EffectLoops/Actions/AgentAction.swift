/// Every possible state mutation in the EffectLoops agent loop.
///
/// Hierarchical — each concern gets its own sub-action enum.
/// The top-level `reduce` dispatches to sub-reducers based on case.
enum AgentAction: Sendable {
  case queue(QueueAction)
  case inference(InferenceAction)
  case tools(ToolsAction)
  case cost(CostAction)
  case transcript(TranscriptAction)
  case settings(SettingsAction)
  case status(StatusAction)
}
