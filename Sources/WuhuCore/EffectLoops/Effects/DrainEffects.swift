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
}
