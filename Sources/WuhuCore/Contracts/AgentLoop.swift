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
      liveVersion += 1
      hasPendingFlushSignal = true
      flushSignal?.yield(())
    }
  }

  private var publishedState: B.State
  private var inflight: [B.StreamAction]?
  private var liveVersion: Int = 0
  private let durableCondition = AsyncCondition<Int>(0)

  // MARK: Lifecycle

  private var started = false
  private var workSignal: AsyncStream<Void>.Continuation?
  private var flushSignal: AsyncStream<Void>.Continuation?
  private var hasPendingWorkSignal = false
  private var hasPendingFlushSignal = false

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

  public func currentStateSnapshot() async -> (state: B.State, hasPendingFlush: Bool) {
    let durableVersion = await durableCondition.current()
    return (
      state: state,
      hasPendingFlush: durableVersion < liveVersion,
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
    hasPendingWorkSignal = true
    workSignal?.yield(())
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started, "AgentLoop.start() called more than once")
    started = true

    let (workStream, workContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    let (flushStream, flushContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    workSignal = workContinuation
    flushSignal = flushContinuation

    if hasPendingWorkSignal || behavior.hasWork(state: state) || behavior.needsInference(state: state) {
      workContinuation.yield(())
    }
    if hasPendingFlushSignal {
      flushContinuation.yield(())
    }

    var terminalError: (any Error)?
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { [weak self] in
          guard let self else { return }
          for await _ in workStream {
            try Task.checkCancellation()
            await consumePendingWorkSignal()
            try await runUntilIdle()
          }
        }

        group.addTask { [weak self] in
          guard let self else { return }
          for await _ in flushStream {
            try Task.checkCancellation()
            await consumePendingFlushSignal()
            try await flushIfNeeded()
          }
        }

        do {
          while try await group.next() != nil {}
        } catch {
          group.cancelAll()
          while let _ = try? await group.next() {}
          throw error
        }
      }
    } catch {
      terminalError = error
    }

    started = false
    workContinuation.finish()
    flushContinuation.finish()
    workSignal = nil
    flushSignal = nil
    await durableCondition.failAll(with: terminalError ?? CancellationError())

    if let terminalError {
      throw terminalError
    }
  }

  private func flushIfNeeded() async throws {
    while let diff = behavior.diff(from: publishedState, to: state) {
      let oldState = publishedState
      let newState = state
      let targetVersion = liveVersion
      let durableState = try await behavior.persist(diff, from: oldState, to: newState)
      publishedState = durableState
      await durableCondition.set(targetVersion)
      emit(.stateUpdated(durableState))
    }
  }

  // MARK: - Agent Loop

  /// Run the loop until idle: (drain → infer → execute persisted tools → compact)*
  private func runUntilIdle() async throws {
    var hasToolResults = false

    if behavior.needsInference(state: state) {
      hasToolResults = true
    }

    while !Task.isCancelled {
      if let call = behavior.nextToolCall(state: state) {
        try await executeNextToolCall(call)
        hasToolResults = true
        continue
      }

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

      if behavior.nextToolCall(state: state) != nil {
        try await waitUntilDurableCurrentVersion()
        hasToolResults = true
        continue
      }

      if behavior.shouldCompact(state: state) {
        let baseState = state
        let compactedState = try await behavior.performCompaction(state: baseState)
        if state == baseState {
          state = compactedState
        } else if behavior.shouldCompact(state: state) {
          hasPendingWorkSignal = true
          workSignal?.yield(())
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

  // MARK: - Tool Execution

  private func executeNextToolCall(_ call: ToolCall) async throws {
    let argsHash = call.arguments.hashValue
    let count = repetitionTracker.preflightCount(toolName: call.name, argsHash: argsHash)

    if count >= ToolCallRepetitionTracker.blockThreshold {
      let blockedResult = behavior.blockedToolResult(for: call)
      behavior.persistToolResult(blockedResult, for: call, state: &state)
      try await waitUntilDurableCurrentVersion()
      return
    }

    let task = behavior.startToolCall(call, state: &state)
    try await waitUntilDurableCurrentVersion()

    let toolResult = await task.value
    let resultHash = toolResult.hashValue
    let recordedCount = repetitionTracker.record(
      toolName: call.name,
      argsHash: argsHash,
      resultHash: resultHash,
    )
    let finalResult: B.ToolResult = if recordedCount >= ToolCallRepetitionTracker.warningThreshold {
      behavior.appendText(ToolCallRepetitionTracker.warningText, to: toolResult)
    } else {
      toolResult
    }
    behavior.persistToolResult(finalResult, for: call, state: &state)
    try await waitUntilDurableCurrentVersion()
  }

  // MARK: - Flush Barriers

  private func waitUntilDurableCurrentVersion() async throws {
    let targetVersion = liveVersion
    let durableVersion = await durableCondition.current()
    guard durableVersion < targetVersion else { return }

    hasPendingFlushSignal = true
    flushSignal?.yield(())
    try await durableCondition.waitUntil(atLeast: targetVersion)
  }

  // MARK: - Emit

  private func emit(_ event: AgentLoopEvent<B.State, B.StreamAction>) {
    for (_, continuation) in observers {
      continuation.yield(event)
    }
  }

  private func consumePendingWorkSignal() {
    hasPendingWorkSignal = false
  }

  private func consumePendingFlushSignal() {
    hasPendingFlushSignal = false
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
