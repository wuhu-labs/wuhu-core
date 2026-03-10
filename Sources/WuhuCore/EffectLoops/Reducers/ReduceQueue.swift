/// Sub-reducer for queue actions.
func reduceQueue(state: inout AgentState, action: QueueAction) {
  switch action {
  case let .systemUpdated(backfill):
    state.queue.system = backfill
    resetInferenceIfFailed(state: &state)
  case let .steerUpdated(backfill):
    state.queue.steer = backfill
    resetInferenceIfFailed(state: &state)
  case let .followUpUpdated(backfill):
    state.queue.followUp = backfill
    resetInferenceIfFailed(state: &state)
  case .drainFinished:
    state.queue.isDraining = false
  }
}

/// When new work arrives, clear a terminal inference failure so
/// the loop can attempt inference again after draining the queue.
private func resetInferenceIfFailed(state: inout AgentState) {
  if state.inference.status == .failed {
    state.inference.status = .idle
    state.inference.retryCount = 0
    state.inference.lastError = nil
  }
}
