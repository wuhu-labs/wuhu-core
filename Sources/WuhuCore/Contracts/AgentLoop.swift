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
      flushSignal.yield(())
    }
  }

  private var publishedState: B.State
  private var inflight: [B.StreamAction]?

  // MARK: Lifecycle

  private var started = false
  private let workStream: AsyncStream<Void>
  private let workSignal: AsyncStream<Void>.Continuation
  private let flushStream: AsyncStream<Void>
  private let flushSignal: AsyncStream<Void>.Continuation

  // MARK: Observation

  private var observers: [UUID: AsyncStream<AgentLoopEvent<B.State, B.StreamAction>>.Continuation] = [:]

  // MARK: Tool Call Repetition

  private var repetitionTracker = ToolCallRepetitionTracker()

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    let (workStream, workSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    let (flushStream, flushSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    self.workStream = workStream
    self.workSignal = workSignal
    self.flushStream = flushStream
    self.flushSignal = flushSignal
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

  public func currentStateSnapshot() -> (state: B.State, hasPendingFlush: Bool) {
    (
      state: state,
      hasPendingFlush: behavior.diff(from: publishedState, to: state) != nil,
    )
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
    let oldState = state
    behavior.handle(action, state: &state)
    guard state != oldState else { return }
    workSignal.yield(())
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
    }

    if behavior.hasWork(state: state) || behavior.needsInference(state: state) {
      workSignal.yield(())
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [weak self] in
        guard let self else { return }
        for await _ in workStream {
          try Task.checkCancellation()
          try await runUntilIdle()
        }
      }

      group.addTask { [weak self] in
        guard let self else { return }
        for await _ in flushStream {
          try Task.checkCancellation()
          try await flushIfNeeded()
        }
      }

      do {
        while try await group.next() != nil {}
      } catch {
        group.cancelAll()
        while let _ = try? await group.next() {}
        publishedState = try await behavior.loadState()
        try await flushIfNeeded()
        throw error
      }
    }
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
      let drainedInterrupts = behavior.drainInterruptItems(state: &state)

      if drainedInterrupts {
        repetitionTracker.reset()
      }

      if !drainedInterrupts, !hasToolResults {
        let drainedTurnItems = behavior.drainTurnItems(state: &state)
        if !drainedTurnItems { break }
      }

      hasToolResults = false

      let context = behavior.buildContext(state: state)
      let message = try await performInferenceWithRetry(context: context)
      behavior.persistAssistantEntry(message, state: &state)

      let toolCalls = message.content.compactMap { block -> ToolCall? in
        if case let .toolCall(call) = block { return call }
        return nil
      }

      if !toolCalls.isEmpty {
        try await executeToolCalls(toolCalls)
        hasToolResults = true
      }

      if behavior.shouldCompact(state: state) {
        let baseState = state
        let compactedState = try await behavior.performCompaction(state: baseState)
        if state == baseState {
          state = compactedState
        } else if behavior.shouldCompact(state: state) {
          workSignal.yield(())
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
      behavior.recoverStaleToolCall(id: id, state: &state)
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
      behavior.toolWillExecute(call, state: &state)
    }

    for call in blocked {
      let error = ToolCallRepetitionError.blocked
      behavior.toolDidFail(call, error: error, state: &state)
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
        behavior.toolDidExecute(call, result: finalResult, state: &state)
      case let .failure(error):
        let argsHash = call.arguments.hashValue
        let errorHash = String(describing: error).hashValue
        repetitionTracker.record(
          toolName: call.name,
          argsHash: argsHash,
          resultHash: errorHash,
        )
        behavior.toolDidFail(call, error: error, state: &state)
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
