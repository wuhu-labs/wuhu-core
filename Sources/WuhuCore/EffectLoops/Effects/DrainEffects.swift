import Foundation
import WuhuAPI

/// Effect factories for draining queue items.
extension AgentBehavior {
  /// Drain all pending queue items (interrupts first, then turn boundary),
  /// persist to DB, and mutate state directly.
  func persistAndDrainAll() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { state in
      guard state.status.snapshot.status != .stopped else { return .none }

      // Drain interrupts (system + steer).
      let interrupts = try await store.drainInterruptCheckpoint(sessionID: sessionID)
      if interrupts.didDrain {
        state.tools.repetitionTracker.reset()
        for entry in interrupts.entries {
          state.transcript.entries.append(entry)
        }
        state.queue.system = interrupts.systemUrgent
        state.queue.steer = interrupts.steer
      }

      // Drain turn boundary (followUp).
      let turn = try await store.drainTurnBoundary(sessionID: sessionID)
      if turn.didDrain {
        for entry in turn.entries {
          state.transcript.entries.append(entry)
        }
        state.queue.followUp = turn.followUp
      }

      // Reset failed inference when new work arrives.
      if interrupts.didDrain || turn.didDrain {
        if state.inference.status == .failed {
          state.inference.status = .idle
          state.inference.retryCount = 0
          state.inference.lastError = nil
        }
      }

      return .none
    }
  }

  /// Drain interrupt-priority items (system + steer queues), persist to DB,
  /// and mutate state directly.
  func persistAndDrainInterrupts() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { state in
      guard state.status.snapshot.status != .stopped else { return .none }

      let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
      guard drained.didDrain else { return .none }

      // Reset repetition tracker when user messages arrive (interrupt/steer).
      state.tools.repetitionTracker.reset()

      for entry in drained.entries {
        state.transcript.entries.append(entry)
      }
      state.queue.system = drained.systemUrgent
      state.queue.steer = drained.steer

      // Reset failed inference when new work arrives.
      if state.inference.status == .failed {
        state.inference.status = .idle
        state.inference.retryCount = 0
        state.inference.lastError = nil
      }

      return .none
    }
  }

  /// Drain turn-boundary items (followUp queue), persist to DB,
  /// and mutate state directly.
  func persistAndDrainTurn() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { state in
      guard state.status.snapshot.status != .stopped else { return .none }

      let drained = try await store.drainTurnBoundary(sessionID: sessionID)
      guard drained.didDrain else { return .none }

      for entry in drained.entries {
        state.transcript.entries.append(entry)
      }
      state.queue.followUp = drained.followUp

      // Reset failed inference when new work arrives.
      if state.inference.status == .failed {
        state.inference.status = .idle
        state.inference.retryCount = 0
        state.inference.lastError = nil
      }

      return .none
    }
  }
}
