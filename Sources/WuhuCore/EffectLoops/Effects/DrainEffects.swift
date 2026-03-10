import Foundation
import WuhuAPI

/// Effect factories for draining queue items (interrupts and turn boundary).
extension AgentBehavior {
  /// Drain interrupt-priority items (system + steer queues), persist to DB,
  /// and return actions that update transcript/queue/status.
  func persistAndDrainInterrupts() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { snapshot in
      guard snapshot.status.snapshot.status != .stopped else { return [] }

      let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
      guard drained.didDrain else { return [] }

      var actions: [AgentAction] = []

      // Reset repetition tracker when user messages arrive (interrupt/steer).
      actions.append(.tools(.resetRepetitions))

      for entry in drained.entries {
        actions.append(.transcript(.append(entry)))
      }
      actions.append(.queue(.systemUpdated(drained.systemUrgent)))
      actions.append(.queue(.steerUpdated(drained.steer)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      actions.append(.status(.updated(status)))

      return actions
    }
  }

  /// Drain turn-boundary items (followUp queue), persist to DB,
  /// and return actions that update transcript/queue/status.
  func persistAndDrainTurn() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { snapshot in
      guard snapshot.status.snapshot.status != .stopped else { return [] }

      let drained = try await store.drainTurnBoundary(sessionID: sessionID)
      guard drained.didDrain else { return [] }

      var actions: [AgentAction] = []

      for entry in drained.entries {
        actions.append(.transcript(.append(entry)))
      }
      actions.append(.queue(.followUpUpdated(drained.followUp)))

      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      actions.append(.status(.updated(status)))

      return actions
    }
  }
}
