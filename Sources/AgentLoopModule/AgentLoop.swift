import AsyncAlgorithms
import AsyncExtensions
import Logging
import Synchronization
import WuhuAI

let logger = Logger(label: "wuhu.AgentLoopModule")

/// Generic agent loop runtime, parameterized by an ``AgentBehavior``.
///
/// Owns a live in-memory state, orchestrates the
/// drain → infer → tools → compact cycle, and only exposes new state to
/// observers after the behavior has durably persisted the diff from the last
/// published state.
public actor AgentLoop<B: AgentBehavior> {
  // MARK: Dependencies

  public nonisolated let behavior: B

  // MARK: State

  var started: Bool = false

  var state: B.State {
    didSet {
      guard state != oldValue else { return }
      liveVersion += 1
      flushSignal.yield(())
    }
  }

  let publishedStates: AsyncCurrentValueSubject<B.State>
  var liveVersion: Int = 0
  var publishedVersion: Int = 0

  let workStream: AsyncStream<Void>
  let workSignal: AsyncStream<Void>.Continuation
  let flushStream: AsyncStream<Void>
  let flushSignal: AsyncStream<Void>.Continuation

  var currentRunningTask: Task<Void, any Error>? = nil
  let interruptionReason: Mutex<B.Interruption?> = Mutex(nil)

  var hasWork: Bool {
    behavior.nextToolCall(state: state) != nil
    || behavior.needsInference(state: state)
    || behavior.shouldCompact(state: state)
  }

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    let (workStream, workSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    let (flushStream, flushSignal) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )

    self.behavior = behavior
    self.state = initialState
    self.publishedStates = AsyncCurrentValueSubject(initialState)
    self.workStream = workStream
    self.workSignal = workSignal
    self.flushStream = flushStream
    self.flushSignal = flushSignal
  }

  // MARK: - Observation

  /// Observe the loop's current published snapshot, gap-free.
  public func observe() -> some AsyncSequence<B.State, Never> {
    publishedStates
  }

  // MARK: - External Actions

  /// Send a domain-specific command into the loop.
  ///
  /// The behavior updates the live in-memory state first. The loop persists the
  /// diff to durable storage and only then publishes the new state.
  public func send(_ action: B.Action) {
    guard let interruption = behavior.handle(action, state: &state) else {
      if currentRunningTask == nil, hasWork {
        workSignal.yield()
      }
      return
    }

    guard let currentRunningTask else { return }
    interruptionReason.withLock {
      guard $0 == nil else { return }
      $0 = interruption
      currentRunningTask.cancel()
    }
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(!started)
    started = true

    defer {
      publishedStates.send(.finished)
    }

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in self.workStream {
          do {
            try await self.startLoop()
          } catch is CancellationError {
          } catch {
            logger.error("Work loop error (behavior should not throw): \(String(describing: error))")
          }
        }
      }

      group.addTask {
        for await _ in self.flushStream {
          do {
            try await self.flushIfNeeded()
          } catch is CancellationError {
          } catch {
            logger.error("Flush error, will retry on next state change: \(String(describing: error))")
          }
        }
      }

      if hasWork {
        workSignal.yield(())
      }
      await group.waitForAll()
    }

    try await flushIfNeeded()
  }

  func flushIfNeeded() async throws {
    while publishedVersion < liveVersion {
      let oldState = publishedStates.value
      let newState = state
      let targetVersion = liveVersion

      // There could be transient state, i.e. for streaming
      if let diff = behavior.diff(from: oldState, to: newState) {
        try await behavior.persist(diff)
      }

      publishedStates.value = newState
      publishedVersion = targetVersion
    }
  }

  // MARK: - Agent Loop

  func startLoop() async throws {
    precondition(currentRunningTask == nil)
    guard hasWork else { return }

    interruptionReason.withLock { $0 = nil }
    let task = Task {
      try await self.loop()
    }
    currentRunningTask = task

    defer {
      interruptionReason.withLock { $0 = nil }
      currentRunningTask = nil
    }

    try await task.value
  }

  /// Run the loop until idle: (drain → infer → execute persisted tools → compact)*
  func loop() async throws {
    while !Task.isCancelled {
      if behavior.nextToolCall(state: state) != nil {
        while let call = behavior.nextToolCall(state: state) {
          let toolResult = try await run(behavior.startToolCall(call, state: &state))
          behavior.persistToolResult(toolResult, for: call, state: &state)
        }
        behavior.drainToContext(state: &state)
        continue
      }

      if behavior.needsInference(state: state) {
        let context = behavior.buildContext(state: state)
        let message = try await run(behavior.infer(context: context))
        behavior.persistAssistantEntry(message, state: &state)
        continue
      }

      if behavior.shouldCompact(state: state) {
        try await run(behavior.performCompaction(state: state))
        continue
      }

      return
    }
  }

  func run<R>(
    _ execution: DeferredExecution<B.Action, B.Interruption, R>
  ) async throws -> R {
    let coordinator = DeferredExecutionCoordinator<B.Action, B.Interruption> { action in
      Task { await self.send(action) }
    }

    try await self.waitForFlush()
    return try await withTaskCancellationHandler {
      try await execution.run(coordinator)
    } onCancel: {
      coordinator.onCancelStorage.withLock { onCancel in
        guard let onCancel else { return }
        let reason = interruptionReason.withLock { $0 }
        onCancel(reason)
      }
    }
  }

  func waitForFlush() async throws {
    let targetVersion = liveVersion
    guard publishedVersion < targetVersion else { return }

    for await _ in publishedStates {
      if publishedVersion >= targetVersion {
        return
      }
    }

    // This happens only when the whole actor is cancelled.
    throw CancellationError()
  }
}
