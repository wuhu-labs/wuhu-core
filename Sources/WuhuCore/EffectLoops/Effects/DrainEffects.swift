import Foundation
import WuhuAPI

/// Effect factories for draining queue items (interrupts and turn boundary).
extension WuhuBehavior {
  /// Drain interrupt-priority items (system + steer queues), persist to DB,
  /// and send transcript/queue/status actions back.
  func persistAndDrainInterrupts(state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store
    return Effect { send in
      defer { Task { await send(WuhuAction.queue(.drainFinished)) } }

      guard state.status.snapshot.status != .stopped else { return }
      let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
      guard drained.didDrain else { return }

      // Reset repetition tracker when user messages arrive (interrupt/steer).
      await send(WuhuAction.tools(.resetRepetitions))

      for entry in drained.entries {
        await send(WuhuAction.transcript(.append(entry)))
      }
      await send(WuhuAction.queue(.systemUpdated(drained.systemUrgent)))
      await send(WuhuAction.queue(.steerUpdated(drained.steer)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(WuhuAction.status(.updated(status)))
    }
  }

  /// Drain turn-boundary items (followUp queue), persist to DB,
  /// and send transcript/queue/status actions back.
  func persistAndDrainTurn(state: WuhuState) -> Effect<WuhuAction> {
    let sessionID = sessionID
    let store = store
    return Effect { send in
      defer { Task { await send(WuhuAction.queue(.drainFinished)) } }

      guard state.status.snapshot.status != .stopped else { return }
      let drained = try await store.drainTurnBoundary(sessionID: sessionID)
      guard drained.didDrain else { return }

      for entry in drained.entries {
        await send(WuhuAction.transcript(.append(entry)))
      }
      await send(WuhuAction.queue(.followUpUpdated(drained.followUp)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(WuhuAction.status(.updated(status)))
    }
  }
}
