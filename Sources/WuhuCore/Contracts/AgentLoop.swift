import Foundation
import WuhuAI

/// Generic agent loop runtime, parameterized by an ``AgentBehavior``.
///
/// Owns a live in-memory state, orchestrates the
/// drain → infer → tools → compact cycle, and only exposes new state to
/// observers after the behavior has durably persisted the diff from the last
/// published state.
public actor AgentLoop<B: AgentBehavior> {
  // MARK: Dependencies

  nonisolated let behavior: B

  // MARK: State

  private(set) var state: B.State {
    didSet {
      guard state != oldValue else { return }
      signal?.yield(())
    }
  }

  private var publishedState: B.State
  private var inflight: [B.StreamAction]?

  // MARK: Lifecycle

  private var started = false
  private var signal: AsyncStream<Void>.Continuation?

  // MARK: Observation

  private var observers: [UUID: AsyncStream<AgentLoopEvent<B.State, B.StreamAction>>.Continuation] = [:]

  // MARK: Tool Call Repetition

  private var repetitionTracker = ToolCallRepetitionTracker()

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    self.behavior = behavior
    state = initialState
    publishedState = initialState
  }

  // MARK: - Observation

  /// Observe the loop's durable state and events, gap-free.
  public func observe() -> AgentLoopObservation<B> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<AgentLoopEvent<B.State, B.StreamAction>>.makeStream()
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { [weak self] in await self?.removeObserver(id) }
    }
    return AgentLoopObservation(state: publishedState, inflight: inflight, events: stream)
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  // MARK: - External Actions

  /// Send a domain-specific command into the loop.
  ///
  /// The behavior updates the live in-memory state first. The loop persists the
  /// diff to durable storage and only then publishes the new state.
  public func send(_ action: B.ExternalAction) async {
    mutate { [behavior] state in
      behavior.handle(action, state: &state)
    }
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "AgentLoop.start() called more than once")
    started = true
    defer {
      started = false
      signal = nil
    }

    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    signal = continuation

    if behavior.hasWork(state: state) {
      signal?.yield(())
    }

    for await _ in stream {
      try await flushIfNeeded()
      try await runUntilIdle()
      try await flushIfNeeded()
    }
  }

  // MARK: - State Transitions

  @discardableResult
  private func mutate(
    _ work: @escaping @Sendable (inout B.State) -> Void,
  ) -> Bool {
    var nextState = state
    work(&nextState)
    guard nextState != state else { return false }
    state = nextState
    return true
  }

  private func flushIfNeeded() async throws {
    while let diff = behavior.diff(from: publishedState, to: state) {
      let oldState = publishedState
      let newState = state
      let durableState = try await behavior.persist(diff, from: oldState, to: newState)
      publishedState = durableState
      emit(.stateUpdated(durableState))
    }
  }

  // MARK: - Agent Loop

  /// Run the loop until idle: recover → (drain → infer → tools → compact)*
  private func runUntilIdle() async throws {
    var hasToolResults = recoverStaleToolCalls()

    if !hasToolResults, behavior.needsInference(state: state) {
      hasToolResults = true
    }

    while !Task.isCancelled {
      let drainedInterrupts = mutate { [behavior] state in
        behavior.drainInterruptItems(state: &state)
      }

      if drainedInterrupts {
        repetitionTracker.reset()
      }

      if !drainedInterrupts, !hasToolResults {
        let drainedTurnItems = mutate { [behavior] state in
          behavior.drainTurnItems(state: &state)
        }
        if !drainedTurnItems { break }
      }

      try await flushIfNeeded()

      hasToolResults = false

      let inferenceBaseState = state
      let context = behavior.buildContext(state: inferenceBaseState)
      let message = try await performInferenceWithRetry(context: context)
      if state != inferenceBaseState {
        try await flushIfNeeded()
      }

      mutate { [behavior] state in
        behavior.persistAssistantEntry(message, state: &state)
      }

      let toolCalls = message.content.compactMap { block -> ToolCall? in
        if case let .toolCall(call) = block { return call }
        return nil
      }

      if !toolCalls.isEmpty {
        try await executeToolCalls(toolCalls)
        try await flushIfNeeded()
        hasToolResults = true
      }

      if behavior.shouldCompact(state: state) {
        let baseState = state
        let compactedState = try await behavior.performCompaction(state: baseState)
        if state == baseState {
          state = compactedState
        } else if behavior.shouldCompact(state: state) {
          signal?.yield(())
        }
      }
    }
  }

  // MARK: - Inference (with streaming + retry)

  private static var maxInferenceRetries: Int {
    10
  }

  private func performInferenceWithRetry(context: Context) async throws -> AssistantMessage {
    var lastError: (any Error)?
    for attempt in 0 ... Self.maxInferenceRetries {
      if attempt > 0 {
        let delay = min(pow(2, Double(attempt - 1)), 60)
        let jitter = delay * Double.random(in: -0.25 ... 0.25)
        let total = UInt64((delay + jitter) * 1_000_000_000)
        try await Task.sleep(nanoseconds: total)
      }

      do {
        return try await performInference(context: context)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        guard Self.isTransientError(error) else { throw error }
      }
    }
    throw lastError ?? AgentLoopError.inferenceProducedNoResult
  }

  private nonisolated static func isTransientError(_ error: any Error) -> Bool {
    if let piError = error as? WuhuAIError,
       case let .httpStatus(code, _) = piError
    {
      return code == 429 || code == 500 || code == 502 || code == 503 || code == 529
    }

    let description = String(describing: error)
    if description.contains("remoteConnectionClosed")
      || description.contains("connectTimeout")
      || description.contains("readTimeout")
    {
      return true
    }

    return false
  }

  private func performInference(context: Context) async throws -> AssistantMessage {
    emit(.streamBegan)
    inflight = []

    defer {
      inflight = nil
      emit(.streamEnded)
    }

    let (deltaStream, deltaContinuation) = AsyncStream<B.StreamAction>.makeStream()
    let sink = AgentStreamSink<B.StreamAction> { deltaContinuation.yield($0) }

    return try await withThrowingTaskGroup(of: AssistantMessage?.self) { group in
      group.addTask { [behavior] in
        defer { deltaContinuation.finish() }
        return try await behavior.infer(context: context, stream: sink)
      }

      for await delta in deltaStream {
        inflight?.append(delta)
        emit(.streamDelta(delta))
      }

      guard let message = try await group.next() ?? nil else {
        throw AgentLoopError.inferenceProducedNoResult
      }
      return message
    }
  }

  // MARK: - Crash Recovery

  private func recoverStaleToolCalls() -> Bool {
    let staleIDs = behavior.staleToolCallIDs(in: state)
    for id in staleIDs {
      mutate { [behavior] state in
        behavior.recoverStaleToolCall(id: id, state: &state)
      }
    }
    return !staleIDs.isEmpty
  }

  // MARK: - Tool Execution

  private func executeToolCalls(_ calls: [ToolCall]) async throws {
    var blocked: [ToolCall] = []
    var allowed: [ToolCall] = []
    for call in calls {
      let argsHash = call.arguments.hashValue
      let count = repetitionTracker.preflightCount(toolName: call.name, argsHash: argsHash)
      if count >= ToolCallRepetitionTracker.blockThreshold {
        blocked.append(call)
      } else {
        allowed.append(call)
      }
    }

    for call in calls {
      mutate { [behavior] state in
        behavior.toolWillExecute(call, state: &state)
      }
    }

    for call in blocked {
      let error = ToolCallRepetitionError.blocked
      mutate { [behavior] state in
        behavior.toolDidFail(call, error: error, state: &state)
      }
    }

    let results: [(ToolCall, Result<B.ToolResult, any Error>)] =
      await withTaskGroup(
        of: (ToolCall, Result<B.ToolResult, any Error>).self,
      ) { [behavior] group in
        for call in allowed {
          group.addTask {
            do {
              let result = try await behavior.executeToolCall(call)
              return (call, .success(result))
            } catch {
              return (call, .failure(error))
            }
          }
        }
        var outputs: [(ToolCall, Result<B.ToolResult, any Error>)] = []
        for await output in group {
          outputs.append(output)
        }
        return outputs
      }

    if state != publishedState {
      try await flushIfNeeded()
    }

    for (call, result) in results {
      switch result {
      case let .success(toolResult):
        let argsHash = call.arguments.hashValue
        let resultHash = toolResult.hashValue
        let count = repetitionTracker.record(
          toolName: call.name,
          argsHash: argsHash,
          resultHash: resultHash,
        )
        let finalResult: B.ToolResult = if count >= ToolCallRepetitionTracker.warningThreshold {
          behavior.appendText(ToolCallRepetitionTracker.warningText, to: toolResult)
        } else {
          toolResult
        }
        mutate { [behavior] state in
          behavior.toolDidExecute(call, result: finalResult, state: &state)
        }
      case let .failure(error):
        let argsHash = call.arguments.hashValue
        let errorHash = String(describing: error).hashValue
        repetitionTracker.record(
          toolName: call.name,
          argsHash: argsHash,
          resultHash: errorHash,
        )
        mutate { [behavior] state in
          behavior.toolDidFail(call, error: error, state: &state)
        }
      }
    }
  }

  // MARK: - Emit

  private func emit(_ event: AgentLoopEvent<B.State, B.StreamAction>) {
    for (_, continuation) in observers {
      continuation.yield(event)
    }
  }
}

// MARK: - Errors

public enum AgentLoopError: Error {
  case inferenceProducedNoResult
}

enum ToolCallRepetitionError: Error, CustomStringConvertible {
  case blocked

  var description: String {
    ToolCallRepetitionTracker.blockText
  }
}
