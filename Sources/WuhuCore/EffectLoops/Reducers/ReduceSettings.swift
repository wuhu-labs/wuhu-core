/// Sub-reducer for settings actions.
func reduceSettings(state: inout WuhuState, action: SettingsAction) {
  switch action {
  case let .updated(snapshot):
    state.settings.snapshot = snapshot
  }
}
