/// Sub-reducer for inference actions.
func reduceInference(state: inout WuhuState, action: InferenceAction) {
  switch action {
  case .started:
    state.inference.status = .running
    state.inference.lastError = nil

  case .delta:
    // Deltas are observed but don't change reducer state.
    // Inflight text tracking happens in the runtime observation layer.
    break

  case .completed:
    state.inference.status = .idle
    state.inference.retryCount = 0
    state.inference.retryAfter = nil
    state.inference.lastError = nil

  case let .failed(error):
    state.inference.lastError = error
    state.inference.retryCount += 1
    // retryAfter will be set by nextEffect in Step 2.
    // For now, just transition to idle on failure.
    state.inference.status = .idle

  case .retryReady:
    state.inference.retryAfter = nil
    state.inference.status = .idle
  }
}
