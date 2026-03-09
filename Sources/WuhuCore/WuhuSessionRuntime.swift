import Foundation
import PiAI
import WuhuAPI

actor WuhuSessionRuntime {
  private let sessionID: SessionID
  private let store: SQLiteSessionStore
  private let eventHub: WuhuLiveEventHub
  private let subscriptionHub: WuhuSessionSubscriptionHub
  private let runtimeConfig: WuhuSessionRuntimeConfig
  private let onIdle: (@Sendable (_ sessionID: String) async -> Void)?

  private var publishedSystemCursor: QueueCursor = .init(rawValue: "0")
  private var publishedSteerCursor: QueueCursor = .init(rawValue: "0")
  private var publishedFollowUpCursor: QueueCursor = .init(rawValue: "0")

  private let behavior: WuhuBehavior
  private var loop: EffectLoop<WuhuBehavior>?

  private var startTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming: Bool = false
  private var inflightText: String = ""
  private var observedState: WuhuState = .empty
  private var observationReady: Bool = false
  private var pendingActions: AsyncStream<WuhuAction>?

  init(
    sessionID: SessionID,
    store: SQLiteSessionStore,
    eventHub: WuhuLiveEventHub,
    subscriptionHub: WuhuSessionSubscriptionHub,
    blobStore: WuhuBlobStore,
    onIdle: (@Sendable (_ sessionID: String) async -> Void)? = nil,
  ) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.subscriptionHub = subscriptionHub
    self.onIdle = onIdle
    runtimeConfig = WuhuSessionRuntimeConfig()
    behavior = WuhuBehavior(
      sessionID: sessionID, store: store,
      runtimeConfig: runtimeConfig, blobStore: blobStore,
    )
  }

  func ensureStarted() async {
    if startTask != nil { return }

    let behavior = behavior
    let store = store
    let sessionID = sessionID

    startTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let parts = try await store.loadLoopStateParts(sessionID: sessionID)
          let initialState = WuhuState(
            transcript: .init(entries: parts.entries),
            queue: .init(system: parts.systemUrgent, steer: parts.steer, followUp: parts.followUp),
            inference: .empty,
            tools: .init(statuses: parts.toolCallStatus, repetitionTracker: ToolCallRepetitionTracker()),
            cost: .empty,
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
          let line = "[WuhuSessionRuntime] loop.start() failed for session '\(sessionID.rawValue)': \(String(describing: error))\n"
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

  private func installLoop(_ newLoop: EffectLoop<WuhuBehavior>, state: WuhuState, actions: AsyncStream<WuhuAction>) {
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

  func setStreamFn(_ streamFn: @escaping StreamFn) async {
    await runtimeConfig.setStreamFn(streamFn)
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

  private func handleAction(_ action: WuhuAction) async {
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
