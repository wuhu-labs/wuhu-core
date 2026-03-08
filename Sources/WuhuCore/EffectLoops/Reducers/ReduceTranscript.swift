/// Sub-reducer for transcript actions.
func reduceTranscript(state: inout WuhuState, action: TranscriptAction) {
  switch action {
  case let .append(entry):
    state.transcript.entries.append(entry)
  }
}
