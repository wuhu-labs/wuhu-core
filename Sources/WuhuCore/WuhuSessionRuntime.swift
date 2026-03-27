import AgentLoopModule
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

  private var startTask: Task<WuhuSessionLoopState?, Never>?
  private var observeTask: Task<Void, Never>?

  private var streaming = false
  private var inflightText = ""
  private var inflightID: UUID?
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
    if startTask != nil { return }

    let initialState = try await behavior.loadState()
    let loop = try await installLoop(initialState: initialState)

    startTask = Task { [weak self, loop, sessionID = sessionID.rawValue, runnerRegistry] in
      guard let self else { return nil }
      var currentLoop = loop

      while !Task.isCancelled {
        do {
          let finalState = try await withDependencies {
            $0.runnerLocator = .live(registry: runnerRegistry)
          } operation: {
            try await currentLoop.start()
          }
          await finishInstalledLoop()
          return finalState
        } catch is CancellationError {
          await finishInstalledLoop()
          return nil
        } catch {
          let line = "[WuhuSessionRuntime] loop.start() failed for session '\(sessionID)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))

          do {
            let reloadedState = try await behavior.loadState()
            currentLoop = try await replaceLoop(initialState: reloadedState)
          } catch {
            let reloadLine = "[WuhuSessionRuntime] loop restart load failed for session '\(sessionID)': \(String(describing: error))\n"
            FileHandle.standardError.write(Data(reloadLine.utf8))
            await finishInstalledLoop()
            return nil
          }

          try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
      }

      await finishInstalledLoop()
      return nil
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
    await loop?.requestStop()

    let start = startTask
    let finalState = await start?.value ?? nil

    startTask = nil
    streaming = false
    inflightText = ""
    inflightID = nil
    observedState = finalState ?? .empty
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

  private func setInitialObservationState(_ observation: AgentLoopObservedState<WuhuSessionLoopState, WuhuSessionStreamAction>) async {
    observedState = observation.state
    inflightID = observation.inflightID
    streaming = observation.inflight != nil
    inflightText = joinedInflightText(from: observation.inflight)
  }

  private func handleObservationSnapshot(_ snapshot: AgentLoopObservedState<WuhuSessionLoopState, WuhuSessionStreamAction>) async {
    let previousState = observedState
    let previousStreaming = streaming
    let previousInflightID = inflightID
    let previousInflightText = inflightText

    let nextState = snapshot.state
    let nextInflightID = snapshot.inflightID
    let nextStreaming = snapshot.inflight != nil
    let nextInflightText = joinedInflightText(from: snapshot.inflight)

    if previousState != nextState {
      let wasIdle = isIdle(state: observedState)
      observedState = nextState
      hasAcceptedInMemoryWork = false

      if let diff = behavior.diff(from: previousState, to: nextState) {
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
    } else {
      observedState = nextState
    }

    if previousInflightID != nextInflightID {
      if previousStreaming {
        streaming = false
        inflightText = ""
        inflightID = nil
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamEnded)
      }

      if nextStreaming {
        streaming = true
        inflightText = ""
        inflightID = nextInflightID
        await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamBegan)
        if !nextInflightText.isEmpty {
          await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(nextInflightText))
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamDelta(nextInflightText))
          inflightText = nextInflightText
        }
      } else if previousStreaming {
        let snapshot = if let loop {
          await loop.currentStateSnapshot()
        } else {
          (state: observedState, hasPendingFlush: false)
        }
        let nowIdle = !snapshot.hasPendingFlush && isIdle(state: snapshot.state)
        if nowIdle {
          await eventHub.publish(sessionID: sessionID.rawValue, event: .idle)
          if let onIdle {
            Task { await onIdle(sessionID.rawValue) }
          }
        }
      }
    } else if nextStreaming {
      streaming = true
      inflightID = nextInflightID
      if nextInflightText != previousInflightText {
        let delta: String = if nextInflightText.hasPrefix(previousInflightText) {
          String(nextInflightText.dropFirst(previousInflightText.count))
        } else {
          nextInflightText
        }
        if !delta.isEmpty {
          await eventHub.publish(sessionID: sessionID.rawValue, event: .assistantTextDelta(delta))
          await subscriptionHub.publish(sessionID: sessionID.rawValue, event: .streamDelta(delta))
        }
      }
      inflightText = nextInflightText
    } else if previousStreaming {
      let wasIdle = isIdle(state: observedState)
      streaming = false
      inflightText = ""
      inflightID = nil
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

  private func joinedInflightText(from inflight: [WuhuSessionStreamAction]?) -> String {
    guard let inflight else { return "" }
    return inflight.map { action in
      switch action {
      case let .assistantTextDelta(text): text
      }
    }.joined()
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

  private func installLoop(initialState: WuhuSessionLoopState) async throws -> AgentLoop<WuhuSessionBehavior> {
    let loop = AgentLoop(behavior: behavior, initialState: initialState)
    self.loop = loop

    let observation = await loop.observe()
    var iterator = observation.makeAsyncIterator()
    guard let initialObservation = try await iterator.next() else {
      throw CancellationError()
    }
    await setInitialObservationState(initialObservation)

    observeTask = Task { [weak self] in
      guard let self else { return }
      do {
        while let snapshot = try await iterator.next() {
          await handleObservationSnapshot(snapshot)
        }
      } catch {
        if !(error is CancellationError) {
          let line = "[WuhuSessionRuntime] observation failed for session '\(sessionID.rawValue)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))
        }
      }
    }

    return loop
  }

  private func replaceLoop(initialState: WuhuSessionLoopState) async throws -> AgentLoop<WuhuSessionBehavior> {
    await finishObservationTask()
    loop = nil
    return try await installLoop(initialState: initialState)
  }

  private func finishInstalledLoop() async {
    await finishObservationTask()
    loop = nil
    observeTask = nil
  }

  private func finishObservationTask() async {
    let observe = observeTask
    observeTask = nil
    _ = await observe?.result
  }
}
