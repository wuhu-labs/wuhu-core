/// Sub-reducer for queue actions.
func reduceQueue(state: inout WuhuState, action: QueueAction) {
  switch action {
  case let .systemUpdated(backfill):
    state.queue.system = backfill
  case let .steerUpdated(backfill):
    state.queue.steer = backfill
  case let .followUpUpdated(backfill):
    state.queue.followUp = backfill
  case .drainFinished:
    state.queue.isDraining = false
  }
}
