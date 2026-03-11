import Dependencies
import Foundation
import PiAI
import ServiceContextModule
import WuhuAPI

/// LoopBehavior implementation for the Wuhu agent loop.
///
/// Dispatches actions to sub-reducers and implements the full
/// `nextEffect` priority ladder for scheduling effects.
///
/// Holds session-scoped dependencies (store, config)
/// that effect factories close over. Created once per session.
struct AgentBehavior: LoopBehavior {
  typealias State = AgentState
  typealias Action = AgentAction
  typealias TaskID = String

  typealias AgentEffect = Effect<AgentState, AgentAction, TaskID>

  // MARK: - Session-scoped dependencies

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: SessionRuntimeConfig
  var dependencyOverrides: (@Sendable (inout DependencyValues) -> Void)?

  // MARK: - Reduce

  func reduce(state: inout AgentState, action: AgentAction) -> AgentEffect {
    switch action {
    case let .queue(a):
      reduceQueue(state: &state, action: a)

    case let .inference(a):
      // Proof-of-concept: short-lived “flip” state (like `pendingCompletion`) is removed.
      // Persist inference completions immediately as a `.sync` effect.
      if case let .completed(message) = a {
        reduceInference(state: &state, action: a)
        return persistInferenceCompletion(message)
      }
      reduceInference(state: &state, action: a)

    case let .tools(a):
      reduceTools(state: &state, action: a)
      if case let .willExecute(call) = a {
        return executeToolCall(call, state: state)
      }
      return .none

    case let .cost(a):
      reduceCost(state: &state, action: a)

    case let .transcript(a):
      reduceTranscript(state: &state, action: a)

    case let .settings(a):
      reduceSettings(state: &state, action: a)

    case let .status(a):
      reduceStatus(state: &state, action: a)
    }
    return .none
  }

  // MARK: - Next Effect

  func nextEffect(state: inout AgentState) -> AgentEffect? {
    switch state.phase {
    case .stopped:
      // Cancel any in-flight work.
      var cancelIDs: [String] = []
      if state.inference.status == .running {
        cancelIDs.append("inference")
        state.inference.status = .idle
      }
      if state.transcript.isCompacting {
        cancelIDs.append("compaction")
        state.transcript.isCompacting = false
      }
      if !state.tools.executingIDs.isEmpty {
        cancelIDs.append(contentsOf: state.tools.executingIDs.map { "tool:\($0)" })
        state.tools.executingIDs.removeAll()
      }
      if state.inference.status == .waitingRetry {
        cancelIDs.append("retry-sleep")
      }
      if !cancelIDs.isEmpty {
        return .cancel(cancelIDs)
      }
      return nil

    case .waitingForTools:
      // Tools are .run tasks — they'll send actions when done.
      // Start any pending (not yet started) tool calls.
      if let call = pendingToolCalls(in: state).first {
        return startToolCall(call)
      }
      return nil

    case .needsDrain:
      return persistAndDrainAll()

    case .needsInference:
      if state.isOverBudget { return nil }
      // Retry backoff.
      if let retryAfter = state.inference.retryAfter {
        state.inference.retryAfter = nil
        return sleepUntil(retryAfter)
      }
      if state.inference.status == .idle {
        state.inference.status = .running
        return runInference(state: state)
      }
      return nil

    case .idle:
      // Compaction — if transcript exceeds threshold.
      if !state.transcript.isCompacting, shouldCompact(state: state) {
        state.transcript.isCompacting = true
        return runCompaction(state: state)
      }
      return nil
    }
  }

  // MARK: - State Queries

  /// Deadline for stale tool call detection (matches worker orphan deadline).
  /// Tool calls are only considered stale after this duration has passed
  /// since they were started, giving the worker time to deliver results
  /// after a server restart.
  static let staleToolCallDeadline: TimeInterval = 3600 // 1 hour

  /// Tool call IDs stuck in `.started` with no result in transcript,
  /// AND past the stale deadline.
  ///
  /// `.pending` tools are not stale — they haven't been picked up yet.
  /// `.started` tools within the deadline are not stale — the worker
  /// may still deliver the result.
  func staleToolCallIDs(in state: AgentState) -> [String] {
    let now = Date()

    var finished: Set<String> = []
    for entry in state.transcript.entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .toolResult(t) = m else { continue }
      finished.insert(t.toolCallId)
    }

    return state.tools.statuses.compactMap { id, record in
      guard record.status == .started else { return nil }
      guard !finished.contains(id) else { return nil }
      guard !state.tools.recoveringIDs.contains(id) else { return nil }
      guard !state.tools.executingIDs.contains(id) else { return nil }
      // Only stale if past deadline
      guard now.timeIntervalSince(record.updatedAt) > Self.staleToolCallDeadline else { return nil }
      return id
    }.sorted()
  }

  /// Find tool calls in `.pending` status (not yet started).
  private func pendingToolCalls(in state: AgentState) -> [ToolCall] {
    let pendingIDs = state.tools.statuses.filter { $0.value.status == .pending }.map(\.key)
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
  private func shouldCompact(state: AgentState) -> Bool {
    let model = modelFromSettings(state.settings.snapshot)
    let settings = CompactionSettings.load(model: model)
    let messages = PromptPreparation.extractContextMessages(from: state.transcript.entries)
    let estimate = CompactionEngine.estimateContextTokens(messages: messages)
    return CompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }

  // MARK: - Run (dependency injection)

  func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
    var ctx = ServiceContext.current ?? .topLevel
    ctx.sessionID = sessionID.rawValue

    try await ServiceContext.$current.withValue(ctx) {
      if let overrides = dependencyOverrides {
        try await withDependencies(overrides) {
          try await work()
        }
      } else {
        try await work()
      }
    }
  }
}
