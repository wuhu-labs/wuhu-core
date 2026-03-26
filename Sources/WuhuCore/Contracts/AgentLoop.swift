import AsyncExtensions
import Foundation
import WuhuAI

private struct PublishedSnapshot<State: Sendable>: Sendable {
  var version: Int
  var state: State
  var inferenceID: UUID?
}

private struct StreamingSnapshot<Action: Sendable>: Sendable {
  var inferenceID: UUID?
  var actions: [Action]?
}

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

  private var liveVersion: Int = 0
  private let publishedSnapshots: AsyncCurrentValueSubject<PublishedSnapshot<B.State>>
  private let streamingSnapshots: AsyncCurrentValueSubject<StreamingSnapshot<B.StreamAction>>
  private let observationSnapshots: AsyncCurrentValueSubject<AgentLoopObservedState<B.State, B.StreamAction>>

  // MARK: Lifecycle

  private var started = false
  private var workSignal: AsyncStream<Void>.Continuation?
  private var flushSignal: AsyncStream<Void>.Continuation?
  private var hasPendingWorkSignal = false
  private var hasPendingFlushSignal = false

  // MARK: Tool Call Repetition

  private var repetitionTracker = ToolCallRepetitionTracker()

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    self.behavior = behavior
    state = initialState
    publishedSnapshots = AsyncCurrentValueSubject(.init(version: 0, state: initialState, inferenceID: nil))
    streamingSnapshots = AsyncCurrentValueSubject(.init(inferenceID: nil, actions: nil))
    observationSnapshots = AsyncCurrentValueSubject(.init(state: initialState, inflightID: nil, inflight: nil))
  }

  // MARK: - Observation

  /// Observe the loop's current published snapshot, gap-free.
  public func observe() -> AsyncCurrentValueSubject<AgentLoopObservedState<B.State, B.StreamAction>> {
    observationSnapshots
  }

  public func currentStateSnapshot() -> (state: B.State, hasPendingFlush: Bool) {
    let published = publishedSnapshots.value
    return (state: state, hasPendingFlush: published.version < liveVersion)
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

    if let terminalError {
      throw terminalError
    }
  }

  private func flushIfNeeded() async throws {
    while let diff = behavior.diff(from: publishedSnapshots.value.state, to: state) {
      let oldState = publishedSnapshots.value.state
      let newState = state
      let targetVersion = liveVersion
      let durableState = try await behavior.persist(diff, from: oldState, to: newState)
      publishedSnapshots.send(.init(
        version: targetVersion,
        state: durableState,
        inferenceID: publishedSnapshots.value.inferenceID,
      ))
      publishObservedSnapshot()
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
    let inferenceID = UUID()
    beginInferenceObservation(inferenceID)

    defer {
      endInferenceObservation(inferenceID)
    }

    let (deltaStream, deltaContinuation) = AsyncStream<B.StreamAction>.makeStream()
    let sink = AgentStreamSink<B.StreamAction> { deltaContinuation.yield($0) }

    return try await withThrowingTaskGroup(of: AssistantMessage?.self) { group in
      group.addTask { [behavior] in
        defer { deltaContinuation.finish() }
        return try await behavior.infer(context: context, stream: sink)
      }

      for await delta in deltaStream {
        appendInflight(delta, inferenceID: inferenceID)
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
    guard publishedSnapshots.value.version < targetVersion else { return }

    hasPendingFlushSignal = true
    flushSignal?.yield(())
    for await snapshot in publishedSnapshots {
      if snapshot.version >= targetVersion {
        return
      }
    }
    throw CancellationError()
  }

  private func beginInferenceObservation(_ inferenceID: UUID) {
    let current = publishedSnapshots.value
    publishedSnapshots.send(.init(
      version: current.version,
      state: current.state,
      inferenceID: inferenceID,
    ))
    streamingSnapshots.send(.init(inferenceID: inferenceID, actions: []))
    publishObservedSnapshot()
  }

  private func appendInflight(_ delta: B.StreamAction, inferenceID: UUID) {
    let current = streamingSnapshots.value
    guard current.inferenceID == inferenceID else { return }
    var actions = current.actions ?? []
    actions.append(delta)
    streamingSnapshots.send(.init(inferenceID: inferenceID, actions: actions))
    publishObservedSnapshot()
  }

  private func endInferenceObservation(_ inferenceID: UUID) {
    if publishedSnapshots.value.inferenceID == inferenceID {
      let current = publishedSnapshots.value
      publishedSnapshots.send(.init(
        version: current.version,
        state: current.state,
        inferenceID: nil,
      ))
    }
    if streamingSnapshots.value.inferenceID == inferenceID {
      streamingSnapshots.send(.init(inferenceID: nil, actions: nil))
    }
    publishObservedSnapshot()
  }

  private func publishObservedSnapshot() {
    let published = publishedSnapshots.value
    let streaming = streamingSnapshots.value
    let inflight: [B.StreamAction]? = if published.inferenceID == streaming.inferenceID {
      streaming.actions
    } else {
      nil
    }
    observationSnapshots.send(.init(
      state: published.state,
      inflightID: published.inferenceID,
      inflight: inflight,
    ))
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
