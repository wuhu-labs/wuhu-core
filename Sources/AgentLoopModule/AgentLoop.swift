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

  var state: B.State {
    didSet {
      guard state != oldValue else { return }
      liveVersion += 1
      flushLoop.nudge()
    }
  }

  let publishedStates: AsyncCurrentValueSubject<B.State>
  var liveVersion: Int = 0
  var publishedVersion: Int = 0

  var workLoop: LoopProcessor!
  var flushLoop: LoopProcessor!

  var currentRunningTask: Task<Void, any Error>? = nil

  var hasWork: Bool {
    behavior.nextToolCall(state: state) != nil
    || behavior.nextContextAction(state: state) != nil
    || behavior.shouldCompact(state: state)
  }

  // MARK: Init

  public init(behavior: B, initialState: B.State) {
    self.behavior = behavior
    self.state = initialState
    self.publishedStates = AsyncCurrentValueSubject(initialState)
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
    behavior.handle(action, state: &state)
    if currentRunningTask == nil, hasWork {
      workLoop.nudge()
    }
  }

  // MARK: - Lifecycle

  /// Start the agent loop. Blocks until cancelled.
  ///
  /// - Precondition: Must not be called more than once.
  public func start() async throws {
    precondition(workLoop == nil)

    workLoop = LoopProcessor {
      try await self.startLoop()
    } onError: { error in
      logger.error("Work loop error (behavior should not throw): \(String(describing: error))")
    }

    flushLoop = LoopProcessor {
      try await self.flushIfNeeded()
    } onError: { error in
      logger.error("Flush error, will retry on next state change: \(String(describing: error))")
    }

    defer {
      publishedStates.send(.finished)
    }

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await self.workLoop.start()
      }
      group.addTask {
        await self.flushLoop.start()
      }

      if hasWork {
        workLoop.nudge()
      }
    }

    try await flushIfNeeded()
  }

  func flushIfNeeded() async throws {
    defer {
      if behavior.autoRetryFailedPersistence, publishedVersion < liveVersion, !Task.isCancelled {
        flushLoop.nudge()
      }
    }

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

    let task = Task {
      try await self.loop()
    }
    currentRunningTask = task

    defer {
      currentRunningTask = nil

      if hasWork {
        // This allows behavior to transition, e.g. from inference to compaction by throwing errors.
        workLoop.nudge()
      }
    }

    try await task.value
  }

  /// Run the loop until idle: (drain → infer → execute persisted tools → compact)*
  func loop() async throws {
    while !Task.isCancelled {
      if behavior.nextToolCall(state: state) != nil {
        while let call = behavior.nextToolCall(state: state) {
          try await run(behavior.startToolCall(call, state: &state))
        }
        behavior.drainToContext(state: &state)
        continue
      }

      if behavior.shouldCompact(state: state) {
        try await run(behavior.performCompaction(state: &state))
        continue
      }

      if let action = behavior.nextContextAction(state: state) {
        switch action {
        case .inference:
          let context = behavior.buildContext(state: state)
          try await run(behavior.infer(context: context, state: &state))
        case .drain:
          behavior.drainToContext(state: &state)
        }
        continue
      }

      return
    }
  }

  func run(
    _ execution: DeferredExecution<B.Action>
  ) async throws {
    let coordinator = DeferredExecutionCoordinator<B.Action> { action in
      Task { await self.send(action) }
    }

    if execution.needsPersistence {
      try await self.waitForFlush()
    }
    try await execution.run(coordinator)
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
