import Foundation
import WuhuAPI

/// Effect factories for draining queue items (interrupts and turn boundary).
extension AgentBehavior {
  /// Drain interrupt-priority items (system + steer queues), persist to DB,
  /// and send transcript/queue/status actions back.
  func persistAndDrainInterrupts(state: AgentState) -> Effect<AgentAction> {
    let sessionID = sessionID
    let store = store
    return Effect { send in
      defer { Task { await send(AgentAction.queue(.drainFinished)) } }

      guard state.status.snapshot.status != .stopped else { return }
      let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
      guard drained.didDrain else { return }

      // Reset repetition tracker when user messages arrive (interrupt/steer).
      await send(AgentAction.tools(.resetRepetitions))

      for entry in drained.entries {
        await send(AgentAction.transcript(.append(entry)))
      }
      await send(AgentAction.queue(.systemUpdated(drained.systemUrgent)))
      await send(AgentAction.queue(.steerUpdated(drained.steer)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(AgentAction.status(.updated(status)))
    }
  }

  /// Drain turn-boundary items (followUp queue), persist to DB,
  /// and send transcript/queue/status actions back.
  func persistAndDrainTurn(state: AgentState) -> Effect<AgentAction> {
    let sessionID = sessionID
    let store = store
    return Effect { send in
      defer { Task { await send(AgentAction.queue(.drainFinished)) } }

      guard state.status.snapshot.status != .stopped else { return }
      let drained = try await store.drainTurnBoundary(sessionID: sessionID)
      guard drained.didDrain else { return }

      for entry in drained.entries {
        await send(AgentAction.transcript(.append(entry)))
      }
      await send(AgentAction.queue(.followUpUpdated(drained.followUp)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      await send(AgentAction.status(.updated(status)))
    }
  }
}
