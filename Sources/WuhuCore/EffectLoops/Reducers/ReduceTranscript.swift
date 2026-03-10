/// Sub-reducer for transcript actions.
func reduceTranscript(state: inout AgentState, action: TranscriptAction) {
  switch action {
  case let .append(entry):
    state.transcript.entries.append(entry)
  case .compactionFinished:
    state.transcript.isCompacting = false
  }
}
