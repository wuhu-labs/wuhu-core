/// Session settings state.
///
/// Maps directly from `WuhuSessionLoopState.settings`.
struct SettingsState: Sendable, Equatable {
  var snapshot: SessionSettingsSnapshot

  static var empty: SettingsState {
    .init(snapshot: .init(effectiveModel: .init(provider: .openai, id: "unknown")))
  }
}
