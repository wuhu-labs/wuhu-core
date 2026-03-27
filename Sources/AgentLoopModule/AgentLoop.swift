import AsyncAlgorithms
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
      flushSignal.yield(())
    }
  }

  private var liveVersion: Int = 0
  private var activeInferenceID: UUID?
  private let publishedSnapshots: AsyncCurrentValueSubject<PublishedSnapshot<B.State>>
  private let streamingSnapshots: AsyncCurrentValueSubject<StreamingSnapshot<B.StreamAction>>

  // MARK: Lifecycle

  private enum Lifecycle {
    case ready
    case running
    case finished
  }

  private var lifecycle: Lifecycle = .ready
  private var stopRequested = false
  private var runningWork = false
  private let workStream: AsyncStream<Void>
  private let workSignal: AsyncStream<Void>.Continuation
  private let flushStream: AsyncStream<Void>
  private let flushSignal: AsyncStream<Void>.Continuation

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    let (workStream, workSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    let (flushStream, flushSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )

    self.behavior = behavior
    state = initialState
    publishedSnapshots = AsyncCurrentValueSubject(.init(version: 0, state: initialState, inferenceID: nil))
    streamingSnapshots = AsyncCurrentValueSubject(.init(inferenceID: nil, actions: nil))
    self.workStream = workStream
    self.workSignal = workSignal
    self.flushStream = flushStream
    self.flushSignal = flushSignal
  }

  // MARK: - Observation

  /// Observe the loop's current published snapshot, gap-free.
  public func observe() -> AgentLoopObservation<B.State, B.StreamAction> {
    combineLatest(publishedSnapshots, streamingSnapshots)
      .map { published, streaming in
        Self.makeObservedState(published: published, streaming: streaming)
      }
      .eraseToAnyAsyncSequence()
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
    guard lifecycle != .finished, !stopRequested else { return }
    let oldState = state
    behavior.handle(action, state: &state)
    guard state != oldState else { return }
    workSignal.yield(())
  }

  public func requestStop() {
    guard lifecycle != .finished else { return }
    stopRequested = true
    workSignal.yield(())
    flushSignal.yield(())
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws -> B.State {
    precondition(lifecycle == .ready, "AgentLoop.start() called more than once")
    lifecycle = .running

    var terminalError: (any Error)?
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { [weak self] in
          guard let self else { return }
          try await workLoop()
        }

        group.addTask { [weak self] in
          guard let self else { return }
          try await flushLoop()
        }

        if behavior.hasWork(state: state) || behavior.needsInference(state: state) {
          workSignal.yield(())
        }
        if publishedSnapshots.value.version < liveVersion {
          flushSignal.yield(())
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

    lifecycle = .finished
    workSignal.finish()
    flushSignal.finish()
    publishedSnapshots.send(.finished)
    streamingSnapshots.send(.finished)

    if let terminalError {
      throw terminalError
    }

    return publishedSnapshots.value.state
  }

  private func workLoop() async throws {
    for await _ in workStream {
      try Task.checkCancellation()

      if shouldFinishWorkLoop {
        break
      }

      runningWork = true
      do {
        try await runUntilIdle()
      } catch {
        runningWork = false
        throw error
      }
      runningWork = false

      if shouldStopWorkLoop {
        flushSignal.yield(())
        break
      }
    }
  }

  private func flushLoop() async throws {
    for await _ in flushStream {
      try Task.checkCancellation()
      try await flushIfNeeded()
      if shouldFinishFlushLoop {
        break
      }
    }
  }

  private func flushIfNeeded() async throws {
    while let diff = behavior.diff(from: publishedSnapshots.value.state, to: state) {
      let oldState = publishedSnapshots.value.state
      let newState = state
      let targetVersion = liveVersion
      let inferenceID = activeInferenceID
      let durableState = try await behavior.persist(diff, from: oldState, to: newState)
      publishedSnapshots.send(.init(
        version: targetVersion,
        state: durableState,
        inferenceID: inferenceID,
      ))
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

      if !drainedInterrupts, !hasToolResults {
        let drainedTurnItems = behavior.drainTurnItems(state: &state)
        if !drainedTurnItems { break }
      }

      hasToolResults = false

      let context = behavior.buildContext(state: state)
      let message = try await performInference(context: context)
      behavior.persistAssistantEntry(message, state: &state)

      if behavior.nextToolCall(state: state) != nil {
        try await waitUntilDurableCurrentVersion()
        hasToolResults = true
        continue
      }

      if behavior.shouldCompact(state: state) {
        state = try await behavior.performCompaction(state: state)
      }
    }
  }

  // MARK: - Inference (with streaming + retry)

  private func performInference(context: Context) async throws -> AssistantMessage {
    let inferenceID = UUID()
    beginInferenceObservation(inferenceID)

    defer {
      endInferenceObservation(inferenceID)
    }

    let (deltaStream, deltaContinuation) = AsyncStream<B.StreamAction>.makeStream()
    let sink = AgentStreamSink<B.StreamAction> { deltaContinuation.yield($0) }

    return try await withThrowingTaskGroup { group in
      group.addTask {
        for await delta in deltaStream {
          await self.appendInflight(delta, inferenceID: inferenceID)
        }
      }
      defer {
        group.cancelAll()
        deltaContinuation.finish()
      }

      return try await behavior.infer(context: context, stream: sink)
    }
  }

  // MARK: - Tool Execution

  private func executeNextToolCall(_ call: ToolCall) async throws {
    let execution = behavior.startToolCall(call, state: &state)
    try await waitUntilDurableCurrentVersion()
    let toolResult = await execution.run()
    behavior.persistToolResult(toolResult, for: call, state: &state)
  }

  // MARK: - Flush Barriers

  private func waitUntilDurableCurrentVersion() async throws {
    let targetVersion = liveVersion
    guard publishedSnapshots.value.version < targetVersion else { return }

    flushSignal.yield(())
    for await snapshot in publishedSnapshots {
      if snapshot.version >= targetVersion {
        return
      }
    }
    throw CancellationError()
  }

  private func beginInferenceObservation(_ inferenceID: UUID) {
    activeInferenceID = inferenceID
    if liveVersion == publishedSnapshots.value.version {
      publishedSnapshots.value.inferenceID = inferenceID
    }
    streamingSnapshots.send(.init(inferenceID: inferenceID, actions: []))
  }

  private func appendInflight(_ delta: B.StreamAction, inferenceID: UUID) {
    let current = streamingSnapshots.value
    guard current.inferenceID == inferenceID else { return }
    var actions = current.actions ?? []
    actions.append(delta)
    streamingSnapshots.send(.init(inferenceID: inferenceID, actions: actions))
  }

  private func endInferenceObservation(_ inferenceID: UUID) {
    if activeInferenceID == inferenceID {
      activeInferenceID = nil
    }
    if liveVersion == publishedSnapshots.value.version,
       publishedSnapshots.value.inferenceID == inferenceID
    {
      publishedSnapshots.value.inferenceID = nil
    }
    if streamingSnapshots.value.inferenceID == inferenceID {
      streamingSnapshots.send(.init(inferenceID: nil, actions: nil))
    }
  }

  private static func makeObservedState(
    published: PublishedSnapshot<B.State>,
    streaming: StreamingSnapshot<B.StreamAction>,
  ) -> AgentLoopObservedState<B.State, B.StreamAction> {
    let inflight: [B.StreamAction]? = if published.inferenceID == streaming.inferenceID {
      streaming.actions
    } else {
      nil
    }
    return .init(
      state: published.state,
      inflightID: published.inferenceID,
      inflight: inflight,
    )
  }

  private var shouldStopWorkLoop: Bool {
    stopRequested
      && !runningWork
      && activeInferenceID == nil
      && !behavior.hasWork(state: state)
      && !behavior.needsInference(state: state)
      && behavior.nextToolCall(state: state) == nil
  }

  private var shouldFinishWorkLoop: Bool {
    shouldStopWorkLoop && publishedSnapshots.value.version >= liveVersion
  }

  private var shouldFinishFlushLoop: Bool {
    shouldStopWorkLoop && publishedSnapshots.value.version >= liveVersion
  }
}
