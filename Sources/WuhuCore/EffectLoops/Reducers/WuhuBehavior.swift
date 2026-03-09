import Foundation
import PiAI
import WuhuAPI

/// LoopBehavior implementation for the Wuhu agent loop.
///
/// Dispatches actions to sub-reducers and implements the full
/// `nextEffect` priority ladder for scheduling effects.
///
/// Holds session-scoped dependencies (store, config, blob store)
/// that effect factories close over. Created once per session.
struct WuhuBehavior: LoopBehavior {
  typealias State = WuhuState
  typealias Action = WuhuAction

  // MARK: - Session-scoped dependencies

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: WuhuSessionRuntimeConfig
  let blobStore: WuhuBlobStore

  // MARK: - Reduce

  func reduce(state: inout WuhuState, action: WuhuAction) {
    switch action {
    case let .queue(a):
      reduceQueue(state: &state, action: a)
    case let .inference(a):
      reduceInference(state: &state, action: a)
    case let .tools(a):
      reduceTools(state: &state, action: a)
    case let .cost(a):
      reduceCost(state: &state, action: a)
    case let .transcript(a):
      reduceTranscript(state: &state, action: a)
    case let .settings(a):
      reduceSettings(state: &state, action: a)
    case let .status(a):
      reduceStatus(state: &state, action: a)
    }
  }

  // MARK: - Next Effect (Priority Ladder)

  func nextEffect(state: inout WuhuState) -> Effect<WuhuAction>? {
    // 1. Cost gate — if paused, emit exceeded entry then idle
    if state.cost.isPaused {
      if !state.cost.exceededEntryEmitted {
        state.cost.exceededEntryEmitted = true
        return emitCostExceededEntry(state: state)
      }
      return nil
    }

    // 2. Retry backoff — if retryAfter is set, clear guard token and sleep
    if let retryAfter = state.inference.retryAfter {
      state.inference.retryAfter = nil // guard token
      return sleepUntil(retryAfter)
    }

    // Only do work when the session is running.
    guard state.status.snapshot.status == .running else { return nil }

    // 3. Stale tool recovery — orphaned tool calls with no result
    let staleIDs = staleToolCallIDs(in: state)
    if let firstStale = staleIDs.first {
      state.tools.recoveringIDs.insert(firstStale) // guard token
      return recoverStaleToolCall(id: firstStale, state: state)
    }

    // 4. Drain interrupts — system + steer queues
    if !state.queue.isDraining,
       !state.queue.system.pending.isEmpty || !state.queue.steer.pending.isEmpty
    {
      state.queue.isDraining = true // guard token
      return persistAndDrainInterrupts(state: state)
    }

    // 5. Drain turn items — followUp queue (only if no interrupts pending)
    if !state.queue.isDraining, !state.queue.followUp.pending.isEmpty {
      state.queue.isDraining = true // guard token
      return persistAndDrainTurn(state: state)
    }

    // 6. Inference — if needed and not already running
    if state.inference.status == .idle, needsInference(state: state) {
      state.inference.status = .running // guard token
      return runInference(state: state)
    }

    // 7. Tool execution — pending tool calls
    let pendingCalls = pendingToolCalls(in: state)
    if !pendingCalls.isEmpty {
      // Mark all as started (guard token) and track as executing
      for call in pendingCalls {
        state.tools.statuses[call.id] = .started
        state.tools.executingIDs.insert(call.id)
      }
      return executeToolCalls(pendingCalls, state: state)
    }

    // 8. Compaction — if transcript exceeds threshold
    if !state.transcript.isCompacting, shouldCompact(state: state) {
      state.transcript.isCompacting = true // guard token
      return runCompaction(state: state)
    }

    return nil
  }

  // MARK: - State Queries

  /// Tool call IDs stuck in `.started` with no result in transcript.
  /// `.pending` tools are not stale — they haven't been picked up yet.
  func staleToolCallIDs(in state: WuhuState) -> [String] {
    var finished: Set<String> = []
    for entry in state.transcript.entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .toolResult(t) = m else { continue }
      finished.insert(t.toolCallId)
    }

    return state.tools.statuses.compactMap { id, status in
      guard status == .started else { return nil }
      guard !finished.contains(id) else { return nil }
      guard !state.tools.recoveringIDs.contains(id) else { return nil }
      guard !state.tools.executingIDs.contains(id) else { return nil }
      return id
    }.sorted()
  }

  /// Whether the transcript is mid-turn and needs an inference call.
  func needsInference(state: WuhuState) -> Bool {
    for entry in state.transcript.entries.reversed() {
      switch entry.payload {
      case let .message(m):
        switch m {
        case .toolResult:
          return true
        case .user:
          return true
        case .assistant:
          return false
        case let .customMessage(c):
          // System input messages (like async bash callbacks) need inference
          if c.customType == WuhuCustomMessageTypes.systemInput { return true }
          continue
        case .unknown:
          continue
        }
      default:
        continue
      }
    }
    return false
  }

  /// Find tool calls in `.pending` status (not yet started).
  private func pendingToolCalls(in state: WuhuState) -> [ToolCall] {
    let pendingIDs = state.tools.statuses.filter { $0.value == .pending }.map(\.key)
    guard !pendingIDs.isEmpty else { return [] }

    var calls: [ToolCall] = []
    let pendingSet = Set(pendingIDs)
    for entry in state.transcript.entries.reversed() {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .assistant(a) = m else { continue }
      for block in a.content {
        guard case let .toolCall(id, name, arguments) = block else { continue }
        if pendingSet.contains(id) {
          calls.append(ToolCall(id: id, name: name, arguments: arguments))
        }
      }
    }
    return calls
  }

  /// Whether compaction should run.
  private func shouldCompact(state: WuhuState) -> Bool {
    let model = modelFromSettings(state.settings.snapshot)
    let settings = WuhuCompactionSettings.load(model: model)
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.transcript.entries)
    let estimate = WuhuCompactionEngine.estimateContextTokens(messages: messages)
    return WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }
}
