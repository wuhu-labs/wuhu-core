/// Full in-memory state for the EffectLoops-based agent loop.
///
/// Composed of sub-states, each owning a logical concern.
/// Maps from the old `WuhuSessionLoopState` — same data, restructured.
struct AgentState: Sendable, Equatable {
  var transcript: TranscriptState
  var queue: QueueState
  var inference: InferenceState
  var tools: ToolsState
  var cost: CostState
  var settings: SettingsState
  var status: StatusState

  /// Total cost derived from assistant message usage in the transcript.
  var totalSpent: Int64 {
    PricingTable.computeCost(entries: transcript.entries)
  }

  /// Whether spending has exceeded the budget limit.
  var isOverBudget: Bool {
    guard let limit = cost.budgetLimit else { return false }
    return totalSpent >= limit
  }

  /// What the loop should do next, derived from current state.
  var phase: LoopPhase {
    if status.snapshot.status == .stopped {
      return .stopped
    }

    // Walk transcript backwards to find the last meaningful entry.
    for entry in transcript.entries.reversed() {
      guard case let .message(m) = entry.payload else { continue }
      switch m {
      case let .assistant(a):
        // If assistant message has tool calls, check if all have results.
        let callIDs = a.content.compactMap { block -> String? in
          if case let .toolCall(id, _, _) = block { return id }
          return nil
        }
        if callIDs.isEmpty {
          // Pure text response, turn is done.
          return .idle
        }
        // Has tool calls — check if any are still waiting for results.
        let hasResult = { (id: String) -> Bool in
          transcript.entries.contains { entry in
            guard case let .message(m) = entry.payload else { return false }
            guard case let .toolResult(t) = m else { return false }
            return t.toolCallId == id
          }
        }
        let allDone = callIDs.allSatisfy(hasResult)
        if !allDone {
          return .waitingForTools
        }
        // All tool calls have results — but we haven't seen a user/toolResult
        // entry *after* this assistant message yet (we're walking backwards and
        // hit assistant first). This shouldn't happen if tool results are appended
        // after the assistant message. Fall through to unknown.
        fatalError("Unexpected: all tool calls done but assistant is last entry")

      case .toolResult:
        // Tool results done. Do we need to drain before inference?
        let hasQueueItems = !queue.system.pending.isEmpty
          || !queue.steer.pending.isEmpty
          || !queue.followUp.pending.isEmpty
        if hasQueueItems {
          return .needsDrain
        }
        return .needsInference

      case .user:
        return .needsInference

      case let .customMessage(c):
        if c.customType == WuhuCustomMessageTypes.systemInput {
          return .needsInference
        }
        continue

      case .unknown:
        continue
      }
    }

    // Empty transcript or only non-message entries.
    return .idle
  }

  static var empty: AgentState {
    .init(
      transcript: .empty,
      queue: .empty,
      inference: .empty,
      tools: .empty,
      cost: .empty,
      settings: .empty,
      status: .empty,
    )
  }
}

/// What the loop should do next.
enum LoopPhase: Sendable, Equatable {
  /// Session is stopped — wind down.
  case stopped
  /// Tool calls are in flight, waiting for results.
  case waitingForTools
  /// Tool results (or user message) ready, but queues have pending items to drain first.
  case needsDrain
  /// Ready for inference (drains done or nothing to drain).
  case needsInference
  /// Nothing to do.
  case idle
}
