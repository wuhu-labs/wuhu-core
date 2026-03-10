import Dependencies
import Foundation
import PiAI
import WuhuAPI

actor SessionRuntime {
  private let sessionID: SessionID
  private let store: SQLiteSessionStore
  private let eventHub: LiveEventHub
  private let subscriptionHub: SessionSubscriptionHub
  private let runtimeConfig: SessionRuntimeConfig
  private let onIdle: (@Sendable (_ sessionID: String) async -> Void)?

  private var publishedSystemCursor: QueueCursor = .init(rawValue: "0")
  private var publishedSteerCursor: QueueCursor = .init(rawValue: "0")
  private var publishedFollowUpCursor: QueueCursor = .init(rawValue: "0")

  private let behavior: AgentBehavior
  private var loop: EffectLoop<AgentBehavior>?

  private var startTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming: Bool = false
  private var inflightText: String = ""
  private var observedState: AgentState = .empty
  private var observationReady: Bool = false
  private var pendingActions: AsyncStream<AgentAction>?

  init(
    sessionID: SessionID,
    store: SQLiteSessionStore,
    eventHub: LiveEventHub,
    subscriptionHub: SessionSubscriptionHub,
    dependencyOverrides: (@Sendable (inout DependencyValues) -> Void)? = nil,
    defaultCostLimitCents: Int64? = nil,
    onIdle: (@Sendable (_ sessionID: String) async -> Void)? = nil,
  ) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.subscriptionHub = subscriptionHub
    self.onIdle = onIdle
    runtimeConfig = SessionRuntimeConfig(defaultCostLimitCents: defaultCostLimitCents)
    behavior = AgentBehavior(
      sessionID: sessionID, store: store,
      runtimeConfig: runtimeConfig,
      dependencyOverrides: dependencyOverrides,
    )
  }

  func ensureStarted() async {
    if startTask != nil { return }

    let behavior = behavior
    let store = store
    let sessionID = sessionID
    let runtimeConfig = runtimeConfig

    startTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let parts = try await store.loadLoopStateParts(sessionID: sessionID)
          let defaultLimit = runtimeConfig.defaultCostLimitCents

          // Compute cost from transcript and populate CostState
          let totalSpent = PricingTable.computeCost(entries: parts.entries)
          let costLimit = parts.costLimitCents ?? defaultLimit
          let budgetRemaining: Int64? = costLimit.map { $0 - totalSpent }
          let isPaused = budgetRemaining.map { $0 <= 0 } ?? false

          let initialState = AgentState(
            transcript: .init(entries: parts.entries),
            queue: .init(system: parts.systemUrgent, steer: parts.steer, followUp: parts.followUp),
            inference: .empty,
            tools: .init(statuses: parts.toolCallStatus, repetitionTracker: ToolCallRepetitionTracker()),
            cost: .init(budgetRemaining: budgetRemaining, totalSpent: totalSpent, isPaused: isPaused, exceededEntryEmitted: false),
            settings: .init(snapshot: parts.settings),
            status: .init(snapshot: parts.status),
          )
          let newLoop = EffectLoop(behavior: behavior, initialState: initialState)
          // Subscribe BEFORE start() so no early actions are lost.
          let (snapshot, actions) = await newLoop.subscribe()
          await self?.installLoop(newLoop, state: snapshot, actions: actions)
          await newLoop.start()
          return
        } catch is CancellationError {
          return
        } catch {
          // Best-effort: keep the per-session loop alive for the process lifetime.
          let line = "[SessionRuntime] loop.start() failed for session '\(sessionID.rawValue)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }
    }

    observeTask = Task { [weak self] in
      guard let self else { return }
      await runObservation()
    }

    while !observationReady {
      await Task.yield()
    }
  }

  private func installLoop(_ newLoop: EffectLoop<AgentBehavior>, state: AgentState, actions: AsyncStream<AgentAction>) {
    loop = newLoop
    observedState = state
    streaming = state.inference.status == .running
    inflightText = ""
    publishedSystemCursor = state.queue.system.cursor
    publishedSteerCursor = state.queue.steer.cursor
    publishedFollowUpCursor = state.queue.followUp.cursor
    pendingActions = actions
    observationReady = true
  }

  private func runObservation() async {
    // Wait for the subscription to be set up by startTask (via installLoop).
    while pendingActions == nil, !Task.isCancelled {
      await Task.yield()
    }
    guard let actions = pendingActions else { return }
    pendingActions = nil

    for await action in actions {
      await handleAction(action)
    }
  }

  func setTools(_ tools: [AnyAgentTool]) async {
    await runtimeConfig.setTools(tools)
  }

  func isIdle() -> Bool {
    if streaming { return false }
    if observedState.status.snapshot.status != .running { return true }
    // Terminal inference failure — the loop has no more work to do
    // until a new user message arrives and resets the error.
    if observedState.inference.status == .failed { return true }
    return false
  }

  /// Returns accumulated streaming text if inference is in progress, nil otherwise.
  func currentInflightText() -> String? {
    guard streaming else { return nil }
    return inflightText
  }

  func dispatchCostLimitUpdated(_ newLimit: Int64) async {
    guard let loop else { return }
    await loop.send(.cost(.limitUpdated(newLimit)))
  }

  func dispatchCostLimitCleared() async {
    guard let loop else { return }
    await loop.send(.cost(.limitCleared))
  }

  /// Deliver a bash result from the worker to the session.
  /// Called when the coordinator receives a result for a tool call with no waiting continuation
  /// (typically after server restart when the worker delivers buffered results).
  func deliverBashResult(toolCallID: String, result: BashResult) async {
    await ensureStarted()
    guard let loop else { return }
    await loop.send(.tools(.bashResultDelivered(toolCallID: toolCallID, result: result)))
  }

  func inProcessExecutionInfo() -> WuhuInProcessExecutionInfo {
    let queued = observedState.queue.followUp.pending.count
    let active = streaming ? 1 : 0
    return .init(activePromptCount: active + queued)
  }

  func enqueue(message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    _ = try await store.enqueueUserMessage(sessionID: sessionID, id: id, message: message, lane: lane)
    let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    guard let loop else { return id }
    switch lane {
    case .steer:
      await loop.send(.queue(.steerUpdated(backfill)))
    case .followUp:
      await loop.send(.queue(.followUpUpdated(backfill)))
    }
    await loop.send(.status(.updated(status)))
    return id
  }

  func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    await ensureStarted()
    try await store.cancelUserMessage(sessionID: sessionID, id: id, lane: lane)
    let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    guard let loop else { return }
    switch lane {
    case .steer:
      await loop.send(.queue(.steerUpdated(backfill)))
    case .followUp:
      await loop.send(.queue(.followUpUpdated(backfill)))
    }
    await loop.send(.status(.updated(status)))
  }

  func enqueueSystem(input: SystemUrgentInput, enqueuedAt: Date = Date()) async throws {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    _ = try await store.enqueueSystemInput(sessionID: sessionID, id: id, input: input, enqueuedAt: enqueuedAt)
    let backfill = try await store.loadSystemQueueBackfill(sessionID: sessionID)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)
    guard let loop else { return }
    await loop.send(.queue(.systemUpdated(backfill)))
    await loop.send(.status(.updated(status)))
  }

  func setModelSelection(_ selection: WuhuSessionSettings) async throws -> Bool {
    await ensureStarted()

    if !streaming, observedState.status.snapshot.status != .running {
      let result = try await store.applyModelSelection(sessionID: sessionID, selection: selection)
      if let loop {
        await loop.send(.transcript(.append(result.entry)))
        await loop.send(.settings(.updated(result.settings)))
        let status = try await store.loadStatusSnapshot(sessionID: sessionID)
        await loop.send(.status(.updated(status)))
      }
      let updated = try await store.getSession(id: sessionID.rawValue)
      return updated.model == selection.model && updated.provider == selection.provider
    }

    let settings = try await store.setPendingModelSelection(sessionID: sessionID, selection: selection)
    if let loop {
      await loop.send(.settings(.updated(settings)))
    }
    return false
  }

  func applyPendingModelIfPossible() async throws {
    await ensureStarted()
    if streaming || observedState.status.snapshot.status == .running { return }
    guard let result = try await store.applyPendingModelIfPossible(sessionID: sessionID) else {
      let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)
      if let loop {
        await loop.send(.settings(.updated(settings)))
      }
      return
    }
    if let loop {
      await loop.send(.transcript(.append(result.entry)))
      await loop.send(.settings(.updated(result.settings)))
    }
  }

  func stop() async {
    let start = startTask
    let observe = observeTask

    start?.cancel()
    observe?.cancel()

    _ = await start?.result
    _ = await observe?.result

    startTask = nil
    observeTask = nil
    loop = nil
    pendingActions = nil
    observationReady = false
    streaming = false
    inflightText = ""
    observedState = .empty

    publishedSystemCursor = .init(rawValue: "0")
    publishedSteerCursor = .init(rawValue: "0")
    publishedFollowUpCursor = .init(rawValue: "0")
  }

  // MARK: - Observation handling

  private func handleAction(_ action: AgentAction) async {
    let wasIdle = isIdle()
    behavior.reduce(state: &observedState, action: action)

    switch action {
    case let .transcript(.append(entry)):
      await eventHub.publish(sessionID: sessionID.rawValue, event: .entryAppended(entry))
      await subscriptionHub.publish(
        sessionID: sessionID.rawValue,
        event: .transcriptAppended([entry]),
      )

    case .transcript(.compactionFinished):
      break

    case .queue(.systemUpdated):
      let delta = try? await store.loadSystemQueueJournal(sessionID: sessionID, since: publishedSystemCursor)
      if let delta {
        publishedSystemCursor = delta.cursor
        if !delta.entries.isEmpty {
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .systemUrgentQueue(cursor: delta.cursor, entries: delta.entries))
        }
      }

    case .queue(.steerUpdated):
      let delta = try? await store.loadUserQueueJournal(sessionID: sessionID, lane: .steer, since: publishedSteerCursor)
      if let delta {
        publishedSteerCursor = delta.cursor
        if !delta.entries.isEmpty {
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .userQueue(cursor: delta.cursor, entries: delta.entries))
        }
      }

    case .queue(.followUpUpdated):
      let delta = try? await store.loadUserQueueJournal(sessionID: sessionID, lane: .followUp, since: publishedFollowUpCursor)
      if let delta {
        publishedFollowUpCursor = delta.cursor
        if !delta.entries.isEmpty {
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .userQueue(cursor: delta.cursor, entries: delta.entries))
        }
      }

    case .queue(.drainFinished):
      break

    case let .settings(.updated(settings)):
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .settingsUpdated(settings))

    case let .status(.updated(status)):
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .statusUpdated(status))

    case .inference(.started):
      streaming = true
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamBegan)

    case let .inference(.delta(text)):
      inflightText += text
      await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(text))
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamDelta(text))

    case .inference(.completed):
      streaming = false
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamEnded)

    case .inference(.failed):
      streaming = false
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamEnded)

    case .inference(.retryReady):
      break

    case .tools:
      break

    case .cost:
      break
    }

    let nowIdle = isIdle()
    if nowIdle, !wasIdle {
      await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
      if let onIdle {
        Task { await onIdle(sessionID.rawValue) }
      }
      // Best-effort: apply deferred model changes once idle.
      Task { [weak self] in
        try? await self?.applyPendingModelIfPossible()
      }
    }
  }
}
