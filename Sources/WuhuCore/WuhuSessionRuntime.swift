import Foundation
import WuhuAI
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

  private let behavior: WuhuSessionBehavior
  private let loop: AgentLoop<WuhuSessionBehavior>

  private var startTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming: Bool = false
  private var inflightText: String = ""
  private var observedState: WuhuSessionLoopState = .empty
  private var observationReady: Bool = false
  private var idlePublished: Bool = false

  init(
    sessionID: SessionID,
    store: SQLiteSessionStore,
    eventHub: WuhuLiveEventHub,
    subscriptionHub: WuhuSessionSubscriptionHub,
    blobStore: WuhuBlobStore,
    streamFn: @escaping StreamFn,
    onIdle: (@Sendable (_ sessionID: String) async -> Void)? = nil,
  ) {
    self.sessionID = sessionID
    self.store = store
    self.eventHub = eventHub
    self.subscriptionHub = subscriptionHub
    self.onIdle = onIdle
    runtimeConfig = WuhuSessionRuntimeConfig()
    behavior = WuhuSessionBehavior(sessionID: sessionID, store: store, runtimeConfig: runtimeConfig, blobStore: blobStore, streamFn: streamFn)
    loop = AgentLoop(behavior: behavior)
  }

  func ensureStarted() async {
    if startTask != nil { return }

    startTask = Task { [loop, sessionID = sessionID.rawValue] in
      while !Task.isCancelled {
        do {
          try await loop.start()
          return
        } catch is CancellationError {
          return
        } catch {
          // Best-effort: keep the per-session loop alive for the process lifetime.
          let line = "[WuhuSessionRuntime] loop.start() failed for session '\(sessionID)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }
    }

    await loop.waitUntilLoaded()

    observeTask = Task { [weak self] in
      guard let self else { return }
      let observation = await loop.observe()
      await setInitialObservationState(observation)
      for await event in observation.events {
        await handleLoopEvent(event)
      }
    }

    while !observationReady {
      await Task.yield()
    }
  }

  func setTools(_ tools: [AnyAgentTool]) async {
    await runtimeConfig.setTools(tools)
  }

  func isIdle() -> Bool {
    // Fast-path: don't block callers on observation if they only need a best-effort hint.
    !streaming && !behavior.hasWork(state: observedState)
  }

  func canEmitInitialIdle(afterReplayCursor lastInitialCursor: Int64, persistedStatus: SessionExecutionStatus?) -> Bool {
    guard observationReady else {
      return persistedStatus != .running
    }
    guard idlePublished, !streaming else { return false }
    return observedState.session.tailEntryID <= lastInitialCursor
  }

  /// Returns accumulated streaming text if inference is in progress, nil otherwise.
  func currentInflightText() -> String? {
    guard streaming else { return nil }
    return inflightText
  }

  func inProcessExecutionInfo() -> WuhuInProcessExecutionInfo {
    let queued = observedState.followUp.pending.count
    let active = streaming ? 1 : 0
    return .init(activePromptCount: active + queued)
  }

  func enqueue(message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    try await loop.send(.enqueueUser(id: id, message: message, lane: lane))
    observedState = await loop.currentState()
    idlePublished = false
    return id
  }

  func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    await ensureStarted()
    try await loop.send(.cancelUser(id: id, lane: lane))
    observedState = await loop.currentState()
  }

  func enqueueSystem(input: SystemUrgentInput, enqueuedAt: Date = Date()) async throws {
    await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    try await loop.send(.enqueueSystem(id: id, input: input, enqueuedAt: enqueuedAt))
    observedState = await loop.currentState()
    idlePublished = false
  }

  func setModelSelection(_ selection: WuhuSessionSettings) async throws -> Bool {
    await ensureStarted()

    if !streaming, !behavior.hasWork(state: observedState) {
      try await loop.send(.applyModelSelection(selection))
      observedState = await loop.currentState()
      // Observe if the session updates quickly; otherwise treat as deferred.
      let updated = try await store.getSession(id: sessionID.rawValue)
      return updated.model == selection.model && updated.provider == selection.provider
    }

    try await loop.send(.setPendingModelSelection(selection))
    observedState = await loop.currentState()
    return false
  }

  func applyPendingModelIfPossible() async throws {
    await ensureStarted()
    if streaming || behavior.hasWork(state: observedState) { return }
    try await loop.send(.applyPendingModelIfPossible)
    observedState = await loop.currentState()
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
    observationReady = false
    streaming = false
    inflightText = ""
    observedState = .empty
    idlePublished = false

    publishedSystemCursor = .init(rawValue: "0")
    publishedSteerCursor = .init(rawValue: "0")
    publishedFollowUpCursor = .init(rawValue: "0")
  }

  // MARK: - Observation handling

  private func setInitialObservationState(_ observation: AgentLoopObservation<WuhuSessionBehavior>) async {
    observedState = observation.state
    streaming = observation.inflight != nil

    // Seed inflight text from the loop's accumulated stream actions.
    if let actions = observation.inflight {
      inflightText = actions.map { action in
        switch action {
        case let .assistantTextDelta(text): text
        }
      }.joined()
    } else {
      inflightText = ""
    }

    publishedSystemCursor = observation.state.systemUrgent.cursor
    publishedSteerCursor = observation.state.steer.cursor
    publishedFollowUpCursor = observation.state.followUp.cursor
    idlePublished = isIdle()

    observationReady = true
  }

  private func handleLoopEvent(_ event: AgentLoopEvent<WuhuSessionMutation, WuhuSessionPersistedEvent, WuhuSessionStreamAction>) async {
    switch event {
    case let .mutated(mutation):
      behavior.apply(mutation, to: &observedState)
      if !isIdle() {
        idlePublished = false
      }

    case let .persisted(event):
      switch event {
      case let .transcriptAppended(entries):
        for entry in entries {
          await eventHub.publish(sessionID: sessionID.rawValue, event: .entryAppended(entry))
        }
        await subscriptionHub.publish(
          sessionID: sessionID.rawValue,
          event: .transcriptAppended(entries),
        )

      case let .systemQueue(cursor, entries):
        publishedSystemCursor = cursor
        if !entries.isEmpty {
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .systemUrgentQueue(cursor: cursor, entries: entries))
        }

      case let .userQueue(lane, cursor, entries):
        switch lane {
        case .steer:
          publishedSteerCursor = cursor
        case .followUp:
          publishedFollowUpCursor = cursor
        }
        if !entries.isEmpty {
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .userQueue(cursor: cursor, entries: entries))
        }

      case let .settingsUpdated(settings):
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .settingsUpdated(settings))

      case let .statusUpdated(status):
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .statusUpdated(status))
      }
      await publishIdleIfNeeded()

    case .streamBegan:
      streaming = true
      inflightText = ""
      idlePublished = false
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamBegan)

    case let .streamDelta(delta):
      switch delta {
      case let .assistantTextDelta(text):
        inflightText += text
        await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(text))
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamDelta(text))
      }

    case .streamEnded:
      streaming = false
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamEnded)
    }
  }

  private func publishIdleIfNeeded() async {
    guard isIdle(), !idlePublished else { return }
    let persistedState = await loop.currentPersistedState()
    guard persistedState == observedState else { return }
    idlePublished = true
    await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
    if let onIdle {
      Task { await onIdle(sessionID.rawValue) }
    }
    Task { [weak self] in
      try? await self?.applyPendingModelIfPossible()
    }
  }
}
