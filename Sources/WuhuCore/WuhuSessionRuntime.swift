import Dependencies
import Foundation
import WuhuAI
import WuhuAPI

actor WuhuSessionRuntime {
  private let sessionID: SessionID
  private let store: SQLiteSessionStore
  private let runnerRegistry: RunnerRegistry
  private let eventHub: WuhuLiveEventHub
  private let subscriptionHub: WuhuSessionSubscriptionHub
  private let runtimeConfig: WuhuSessionRuntimeConfig
  private let onIdle: (@Sendable (_ sessionID: String) async -> Void)?

  private let behavior: WuhuSessionBehavior
  private var loop: AgentLoop<WuhuSessionBehavior>?

  private var startTask: Task<Void, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming = false
  private var inflightText = ""
  private var observedState: WuhuSessionLoopState = .empty
  private var hasAcceptedInMemoryWork = false

  init(
    sessionID: SessionID,
    store: SQLiteSessionStore,
    runnerRegistry: RunnerRegistry,
    braveSearchAPIKey: String?,
    eventHub: WuhuLiveEventHub,
    subscriptionHub: WuhuSessionSubscriptionHub,
    blobStore: WuhuBlobStore,
    streamFn: @escaping StreamFn,
    onIdle: (@Sendable (_ sessionID: String) async -> Void)? = nil,
  ) {
    self.sessionID = sessionID
    self.store = store
    self.runnerRegistry = runnerRegistry
    self.eventHub = eventHub
    self.subscriptionHub = subscriptionHub
    self.onIdle = onIdle
    runtimeConfig = WuhuSessionRuntimeConfig(braveSearchAPIKey: braveSearchAPIKey)
    behavior = WuhuSessionBehavior(sessionID: sessionID, store: store, runtimeConfig: runtimeConfig, blobStore: blobStore, streamFn: streamFn)
  }

  func ensureStarted() async throws {
    if startTask != nil, loop != nil { return }

    let initialState = try await behavior.loadState()
    let loop = AgentLoop(behavior: behavior, initialState: initialState)
    self.loop = loop

    let observation = await loop.observe()
    await setInitialObservationState(observation)

    observeTask = Task { [weak self] in
      guard let self else { return }
      for await event in observation.events {
        await handleLoopEvent(event)
      }
    }

    startTask = Task { [loop, sessionID = sessionID.rawValue, runnerRegistry] in
      while !Task.isCancelled {
        do {
          try await withDependencies {
            $0.runnerLocator = .live(registry: runnerRegistry)
          } operation: {
            try await loop.start()
          }
          return
        } catch is CancellationError {
          return
        } catch {
          let line = "[WuhuSessionRuntime] loop.start() failed for session '\(sessionID)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))
          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }
    }
  }

  func setToolProvider(_ provider: @escaping WuhuSessionToolProvider) async {
    await runtimeConfig.setToolProvider(provider)
  }

  func isIdle() -> Bool {
    isIdle(state: observedState)
  }

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
    try await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    guard let loop else { throw CancellationError() }
    await loop.send(.enqueueUser(id: id, message: message, lane: lane))
    hasAcceptedInMemoryWork = true
    return id
  }

  func cancel(id: QueueItemID, lane: UserQueueLane) async throws {
    try await ensureStarted()
    guard let loop else { throw CancellationError() }
    await loop.send(.cancelUser(id: id, lane: lane))
    hasAcceptedInMemoryWork = true
  }

  func enqueueSystem(input: SystemUrgentInput, enqueuedAt: Date = Date()) async throws {
    try await ensureStarted()
    let id = QueueItemID(rawValue: UUID().uuidString.lowercased())
    guard let loop else { throw CancellationError() }
    await loop.send(.enqueueSystem(id: id, input: input, enqueuedAt: enqueuedAt))
    hasAcceptedInMemoryWork = true
  }

  func setCustomTitle(_ title: String?) async throws -> WuhuSession {
    try await ensureStarted()
    guard let loop else { throw CancellationError() }
    await loop.send(.setCustomTitle(title))
    return try await currentSession()
  }

  func setArchived(_ isArchived: Bool) async throws -> WuhuSession {
    try await ensureStarted()
    guard let loop else { throw CancellationError() }
    await loop.send(.setArchived(isArchived))
    return try await currentSession()
  }

  func setCwd(_ cwd: String?) async throws -> WuhuSession {
    try await ensureStarted()
    guard let loop else { throw CancellationError() }
    await loop.send(.setCwd(cwd))
    return try await currentSession()
  }

  func setModelSelection(_ selection: WuhuSessionSettings) async throws -> Bool {
    try await ensureStarted()
    guard let loop else { throw CancellationError() }

    if !streaming, !behavior.hasWork(state: observedState) {
      await loop.send(.applyModelSelection(selection))
      return true
    }

    await loop.send(.setPendingModelSelection(selection))
    return false
  }

  func applyPendingModelIfPossible() async throws {
    try await ensureStarted()
    if streaming || behavior.hasWork(state: observedState) { return }
    guard let loop else { throw CancellationError() }
    await loop.send(.applyPendingModelIfPossible)
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
    streaming = false
    inflightText = ""
    observedState = .empty
    hasAcceptedInMemoryWork = false
  }

  private func currentSession() async throws -> WuhuSession {
    if let loop {
      return await loop.currentStateSnapshot().state.session
    }
    if observedState.session.id == sessionID.rawValue {
      return observedState.session
    }
    throw CancellationError()
  }

  private func setInitialObservationState(_ observation: AgentLoopObservation<WuhuSessionBehavior>) async {
    observedState = observation.state
    streaming = observation.inflight != nil

    if let actions = observation.inflight {
      inflightText = actions.map { action in
        switch action {
        case let .assistantTextDelta(text): text
        }
      }.joined()
    } else {
      inflightText = ""
    }
  }

  private func handleLoopEvent(_ event: AgentLoopEvent<WuhuSessionLoopState, WuhuSessionStreamAction>) async {
    switch event {
    case let .stateUpdated(nextState):
      let wasIdle = isIdle(state: observedState)
      let oldState = observedState
      observedState = nextState
      hasAcceptedInMemoryWork = false

      if let diff = behavior.diff(from: oldState, to: nextState) {
        await publish(diff: diff, nextState: nextState)
      }

      let nowIdle = isIdle(state: nextState)
      if nowIdle, !wasIdle {
        await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
        if let onIdle {
          Task { await onIdle(sessionID.rawValue) }
        }
        Task { [weak self] in
          try? await self?.applyPendingModelIfPossible()
        }
      }

    case .streamBegan:
      streaming = true
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamBegan)

    case let .streamDelta(delta):
      switch delta {
      case let .assistantTextDelta(text):
        inflightText += text
        await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(text))
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamDelta(text))
      }

    case .streamEnded:
      let wasIdle = isIdle(state: observedState)
      streaming = false
      inflightText = ""
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamEnded)
      let snapshot = if let loop {
        await loop.currentStateSnapshot()
      } else {
        (state: observedState, hasPendingFlush: false)
      }
      let nowIdle = !snapshot.hasPendingFlush && isIdle(state: snapshot.state)
      if nowIdle, !wasIdle {
        await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
        if let onIdle {
          Task { await onIdle(sessionID.rawValue) }
        }
      }
    }
  }

  private func isIdle(state: WuhuSessionLoopState) -> Bool {
    !streaming && !hasAcceptedInMemoryWork && !behavior.hasWork(state: state)
  }

  private func publish(diff: WuhuSessionPersistenceDiff, nextState: WuhuSessionLoopState) async {
    if !diff.appendedEntries.isEmpty {
      for entry in diff.appendedEntries {
        await eventHub.publish(sessionID: sessionID.rawValue, event: .entryAppended(entry))
      }
      await subscriptionHub.publish(
        sessionID: sessionID.rawValue,
        event: .transcriptAppended(diff.appendedEntries),
      )
    }

    if !diff.systemJournalEntries.isEmpty {
      await subscriptionHub.publish(
        sessionID: sessionID.rawValue,
        event: .systemUrgentQueue(cursor: nextState.systemUrgent.cursor, entries: diff.systemJournalEntries),
      )
    }

    if !diff.steerJournalEntries.isEmpty {
      await subscriptionHub.publish(
        sessionID: sessionID.rawValue,
        event: .userQueue(cursor: nextState.steer.cursor, entries: diff.steerJournalEntries),
      )
    }

    if !diff.followUpJournalEntries.isEmpty {
      await subscriptionHub.publish(
        sessionID: sessionID.rawValue,
        event: .userQueue(cursor: nextState.followUp.cursor, entries: diff.followUpJournalEntries),
      )
    }

    if diff.settingsChanged {
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .settingsUpdated(nextState.settings))
    }

    if diff.statusChanged {
      await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .statusUpdated(nextState.status))
    }
  }
}
