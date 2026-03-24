import Foundation
import WuhuAI
import WuhuAPI

enum WuhuSessionStreamAction: Sendable, Hashable {
  case assistantTextDelta(String)
}

enum WuhuSessionExternalAction: Sendable, Hashable {
  case enqueueUser(id: QueueItemID, message: QueuedUserMessage, lane: UserQueueLane)
  case cancelUser(id: QueueItemID, lane: UserQueueLane)
  case enqueueSystem(id: QueueItemID, input: SystemUrgentInput, enqueuedAt: Date)

  case setPendingModelSelection(WuhuSessionSettings)
  case applyModelSelection(WuhuSessionSettings)
  case applyPendingModelIfPossible
}

enum WuhuSessionMutation: Sendable, Hashable {
  case sessionUpdated(WuhuSession)
  case entryAppended(WuhuSessionEntry)
  case toolCallStatusUpdated(id: String, status: ToolCallStatus)
  case systemQueueUpdated(SystemUrgentQueueBackfill)
  case userQueueUpdated(lane: UserQueueLane, backfill: UserQueueBackfill)
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)
}

enum WuhuSessionPersistedEvent: Sendable, Hashable {
  case transcriptAppended([WuhuSessionEntry])
  case systemQueue(cursor: QueueCursor, entries: [SystemUrgentQueueJournalEntry])
  case userQueue(lane: UserQueueLane, cursor: QueueCursor, entries: [UserQueueJournalEntry])
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)
}

struct WuhuSessionLoopState: Sendable, Equatable {
  var session: WuhuSession
  var toolCallStatus: [String: ToolCallStatus]
  var entries: [WuhuSessionEntry]
  var settings: SessionSettingsSnapshot
  var status: SessionStatusSnapshot
  var systemUrgent: SystemUrgentQueueBackfill
  var steer: UserQueueBackfill
  var followUp: UserQueueBackfill

  static var empty: WuhuSessionLoopState {
    .init(
      session: .init(
        id: "",
        provider: .openai,
        model: "unknown",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        headEntryID: 0,
        tailEntryID: 0,
      ),
      toolCallStatus: [:],
      entries: [],
      settings: .init(effectiveModel: .init(provider: .openai, id: "unknown")),
      status: .init(status: .idle),
      systemUrgent: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )
  }
}

struct WuhuSessionBehavior: AgentBehavior {
  typealias State = WuhuSessionLoopState
  typealias Mutation = WuhuSessionMutation
  typealias PersistedEvent = WuhuSessionPersistedEvent
  typealias StreamAction = WuhuSessionStreamAction
  typealias ExternalAction = WuhuSessionExternalAction
  typealias ToolResult = AgentToolResult

  static var emptyState: WuhuSessionLoopState {
    .empty
  }

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: WuhuSessionRuntimeConfig
  let blobStore: WuhuBlobStore
  let streamFn: StreamFn

  func loadState() async throws -> State {
    let parts = try await store.loadLoopStateParts(sessionID: sessionID)
    return .init(
      session: parts.session,
      toolCallStatus: parts.toolCallStatus,
      entries: parts.entries,
      settings: parts.settings,
      status: parts.status,
      systemUrgent: parts.systemUrgent,
      steer: parts.steer,
      followUp: parts.followUp,
    )
  }

  func apply(_ mutation: Mutation, to state: inout State) {
    switch mutation {
    case let .sessionUpdated(session):
      state.session = session
    case let .entryAppended(entry):
      state.entries.append(entry)
    case let .toolCallStatusUpdated(id, status):
      state.toolCallStatus[id] = status
    case let .systemQueueUpdated(backfill):
      state.systemUrgent = backfill
    case let .userQueueUpdated(lane, backfill):
      switch lane {
      case .steer:
        state.steer = backfill
      case .followUp:
        state.followUp = backfill
      }
    case let .settingsUpdated(settings):
      state.settings = settings
    case let .statusUpdated(status):
      state.status = status
    }
  }

  func handle(_ action: ExternalAction, state: State) async throws -> [Mutation] {
    switch action {
    case let .enqueueUser(id, message, lane):
      let item = UserQueuePendingItem(id: id, enqueuedAt: Date(), message: message)
      let backfill = enqueueUser(item: item, lane: lane, into: state)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(.init(status: .running)),
      ]

    case let .cancelUser(id, lane):
      let backfill = try cancelUser(id: id, lane: lane, from: state)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(.init(status: statusAfterUserCancel(from: state, replacing: backfill, lane: lane))),
      ]

    case let .enqueueSystem(id, input, enqueuedAt):
      let item = SystemUrgentPendingItem(id: id, enqueuedAt: enqueuedAt, input: input)
      let backfill = enqueueSystem(item: item, into: state)
      return [
        .systemQueueUpdated(backfill),
        .statusUpdated(.init(status: .running)),
      ]

    case let .setPendingModelSelection(selection):
      return [.settingsUpdated(setPendingModelSelection(selection, from: state.settings))]

    case let .applyModelSelection(selection):
      return try await applyModelSelection(selection, state: state)

    case .applyPendingModelIfPossible:
      guard let pending = state.settings.pendingModel else { return [] }
      guard state.status.status == .idle, !hasPendingWork(state) else { return [] }
      let selection = WuhuSessionSettings(
        provider: WuhuProvider(rawValue: pending.provider.rawValue) ?? .openai,
        model: pending.id,
        reasoningEffort: state.settings.pendingReasoningEffort,
      )
      return try await applyModelSelection(selection, state: state)
    }
  }

  func drainInterruptItems(state: State) async throws -> [Mutation] {
    if state.status.status == .stopped { return [] }

    struct Candidate {
      enum Kind {
        case system(SystemUrgentPendingItem)
        case steer(UserQueuePendingItem)
      }

      var enqueuedAt: Date
      var stableID: String
      var kind: Kind
    }

    var candidates: [Candidate] = state.systemUrgent.pending.map {
      .init(enqueuedAt: $0.enqueuedAt, stableID: $0.id.rawValue, kind: .system($0))
    }
    candidates += state.steer.pending.map {
      .init(enqueuedAt: $0.enqueuedAt, stableID: $0.id.rawValue, kind: .steer($0))
    }
    candidates.sort { a, b in
      if a.enqueuedAt != b.enqueuedAt { return a.enqueuedAt < b.enqueuedAt }
      return a.stableID < b.stableID
    }

    guard !candidates.isEmpty else { return [] }

    let entryIDs = try await store.reserveEntryIDs(count: candidates.count)
    var nextSession = state.session
    var appended: [WuhuSessionEntry] = []
    appended.reserveCapacity(candidates.count)

    var nextSystem = state.systemUrgent
    nextSystem.pending = []
    var nextSteer = state.steer
    nextSteer.pending = []

    for (candidate, entryID) in zip(candidates, entryIDs) {
      let entry: WuhuSessionEntry
      switch candidate.kind {
      case let .system(item):
        entry = appendEntry(
          id: entryID,
          createdAt: item.enqueuedAt,
          payload: materializedPayload(for: item),
          to: &nextSession,
        )
        nextSystem.journal.append(.materialized(
          id: item.id,
          transcriptEntryID: .init(rawValue: "\(entry.id)"),
          at: Date(),
        ))
      case let .steer(item):
        entry = appendEntry(
          id: entryID,
          createdAt: item.enqueuedAt,
          payload: materializedPayload(for: item),
          to: &nextSession,
        )
        nextSteer.journal.append(.materialized(
          lane: .steer,
          id: item.id,
          transcriptEntryID: .init(rawValue: "\(entry.id)"),
          at: Date(),
        ))
      }
      appended.append(entry)
    }

    nextSystem.cursor = advancedCursor(nextSystem.cursor, by: state.systemUrgent.pending.count)
    nextSteer.cursor = advancedCursor(nextSteer.cursor, by: state.steer.pending.count)

    var mutations: [Mutation] = [.sessionUpdated(nextSession)]
    mutations += appended.map(Mutation.entryAppended)
    mutations.append(.systemQueueUpdated(nextSystem))
    mutations.append(.userQueueUpdated(lane: .steer, backfill: nextSteer))
    return mutations
  }

  func drainTurnItems(state: State) async throws -> [Mutation] {
    if state.status.status == .stopped { return [] }
    guard !state.followUp.pending.isEmpty else { return [] }

    let items = state.followUp.pending.sorted {
      if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
      return $0.id.rawValue < $1.id.rawValue
    }
    let entryIDs = try await store.reserveEntryIDs(count: items.count)

    var nextSession = state.session
    var appended: [WuhuSessionEntry] = []
    appended.reserveCapacity(items.count)
    var nextFollowUp = state.followUp
    nextFollowUp.pending = []

    for (item, entryID) in zip(items, entryIDs) {
      let entry = appendEntry(
        id: entryID,
        createdAt: item.enqueuedAt,
        payload: materializedPayload(for: item),
        to: &nextSession,
      )
      appended.append(entry)
      nextFollowUp.journal.append(.materialized(
        lane: .followUp,
        id: item.id,
        transcriptEntryID: .init(rawValue: "\(entry.id)"),
        at: Date(),
      ))
    }
    nextFollowUp.cursor = advancedCursor(nextFollowUp.cursor, by: items.count)

    var mutations: [Mutation] = [.sessionUpdated(nextSession)]
    mutations += appended.map(Mutation.entryAppended)
    mutations.append(.userQueueUpdated(lane: .followUp, backfill: nextFollowUp))
    return mutations
  }

  func buildContext(state: State) -> Context {
    let header = (try? WuhuPromptPreparation.extractHeader(from: state.entries, sessionID: sessionID.rawValue))
    let systemPrompt = header?.systemPrompt ?? ""
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let hydrated = hydrateImageBlobs(in: messages)
    return Context(systemPrompt: systemPrompt, messages: hydrated, tools: [])
  }

  func infer(context: Context, stream: AgentStreamSink<StreamAction>) async throws -> AssistantMessage {
    let session = try await store.getSession(id: sessionID.rawValue)
    let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)

    let resolved = WuhuModelCatalog.resolveAlias(session.model)
    let provider = session.provider.piProvider
    let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
    var requestOptions = makeRequestOptions(model: apiModel, settings: settings, userModelID: session.model)
    requestOptions.sessionId = sessionID.rawValue
    mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)

    let tools = await runtimeConfig.tools()

    var effectiveSystemPrompt = context.systemPrompt ?? ""
    if let cwd = session.cwd {
      effectiveSystemPrompt += "\n\nWorking directory: \(cwd)\nAll relative paths are resolved from this directory."
    }

    let effectiveContext = Context(
      systemPrompt: effectiveSystemPrompt,
      messages: context.messages,
      tools: tools.map(\.tool),
    )

    let events = try await streamFn(apiModel, effectiveContext, requestOptions)

    var partial: AssistantMessage?
    var final: AssistantMessage?
    for try await event in events {
      switch event {
      case let .start(p):
        partial = p
      case let .textDelta(delta, p):
        stream.yield(.assistantTextDelta(delta))
        partial = p
      case let .done(message):
        final = message
      }
    }
    if let final { return final }
    if let partial { return partial }
    throw WuhuAIError.unsupported("No model output")
  }

  func persistAssistantEntry(_ message: AssistantMessage, state: State) async throws -> [Mutation] {
    let id = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(
      id: id,
      createdAt: message.timestamp,
      payload: .message(.fromPi(.assistant(message))),
      to: &nextSession,
    )

    var mutations: [Mutation] = [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
    ]

    let calls = message.content.compactMap { block -> ToolCall? in
      if case let .toolCall(c) = block { return c }
      return nil
    }
    for call in calls {
      mutations.append(.toolCallStatusUpdated(id: call.id, status: .pending))
    }

    let nextStatus: SessionExecutionStatus = if !calls.isEmpty {
      .running
    } else {
      statusAfterApplying(mutations, to: state)
    }
    mutations.append(.statusUpdated(.init(status: nextStatus)))
    return mutations
  }

  func toolWillExecute(_ call: ToolCall, state _: State) async throws -> [Mutation] {
    [
      .toolCallStatusUpdated(id: call.id, status: .started),
      .statusUpdated(.init(status: .running)),
    ]
  }

  func executeToolCall(_ call: ToolCall) async throws -> ToolResult {
    let tools = await runtimeConfig.tools()
    guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
      throw WuhuAIError.unsupported("Unknown tool: \(call.name)")
    }
    return try await tool.execute(toolCallId: call.id, args: call.arguments)
  }

  func appendText(_ text: String, to result: AgentToolResult) -> AgentToolResult {
    var copy = result
    copy.content.append(.text(text))
    return copy
  }

  func toolDidExecute(_ call: ToolCall, result: ToolResult, state: State) async throws -> [Mutation] {
    let now = Date()

    let persistedContent = try result.content.map { block -> WuhuContentBlock in
      if case let .image(img) = block, !img.data.hasPrefix("blob://") {
        guard let rawData = Data(base64Encoded: img.data) else {
          return WuhuContentBlock.fromPi(block)
        }
        let uri = try blobStore.store(sessionID: sessionID.rawValue, data: rawData, mimeType: img.mimeType)
        return .image(blobURI: uri, mimeType: img.mimeType)
      }
      return WuhuContentBlock.fromPi(block)
    }

    let toolResultMessage = WuhuToolResultMessage(
      toolCallId: call.id,
      toolName: call.name,
      content: persistedContent,
      details: result.details,
      isError: false,
      timestamp: now,
    )

    let entryID = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(
      id: entryID,
      createdAt: now,
      payload: .message(.toolResult(toolResultMessage)),
      to: &nextSession,
    )

    return [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: call.id, status: .completed),
      .statusUpdated(.init(status: .running)),
    ]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state: State) async throws -> [Mutation] {
    let now = Date()
    let toolResult: Message = .toolResult(.init(
      toolCallId: call.id,
      toolName: call.name,
      content: [.text("[tool error] \(error)")],
      details: .object([
        "wuhu_tool_error": .string("\(error)"),
      ]),
      isError: true,
      timestamp: now,
    ))

    let entryID = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(
      id: entryID,
      createdAt: now,
      payload: .message(.fromPi(toolResult)),
      to: &nextSession,
    )

    return [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: call.id, status: .errored),
      .statusUpdated(.init(status: .running)),
    ]
  }

  func shouldCompact(state: State) -> Bool {
    let model = modelFromSettings(state.settings)
    let settings = WuhuCompactionSettings.load(model: model)
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let estimate = WuhuCompactionEngine.estimateContextTokens(messages: messages)
    return WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }

  func performCompaction(state: State) async throws -> [Mutation] {
    let session = state.session
    let provider = session.provider.piProvider
    let settingsModel = Model(id: session.model, provider: provider)
    let settings = WuhuCompactionSettings.load(model: settingsModel)

    guard let prep = WuhuCompactionEngine.prepareCompaction(transcript: state.entries, settings: settings) else {
      return []
    }

    let resolved = WuhuModelCatalog.resolveAlias(session.model)
    let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
    var requestOptions = makeRequestOptions(model: apiModel, settings: state.settings, userModelID: session.model)
    requestOptions.sessionId = sessionID.rawValue
    mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)
    let summary = try await WuhuCompactionEngine.generateSummary(
      preparation: prep,
      model: apiModel,
      settings: settings,
      requestOptions: requestOptions,
      streamFn: streamFn,
    )

    let payload: WuhuEntryPayload = .compaction(.init(
      summary: summary,
      tokensBefore: prep.tokensBefore,
      firstKeptEntryID: prep.firstKeptEntryID,
    ))

    let entryID = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(id: entryID, createdAt: Date(), payload: payload, to: &nextSession)

    return [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
      .statusUpdated(state.status),
    ]
  }

  func staleToolCallIDs(in state: State) -> [String] {
    var finished: Set<String> = []
    for entry in state.entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .toolResult(t) = m else { continue }
      finished.insert(t.toolCallId)
    }

    return state.toolCallStatus.compactMap { id, status in
      guard status == .started || status == .pending else { return nil }
      return finished.contains(id) ? nil : id
    }.sorted()
  }

  func recoverStaleToolCall(id: String, state: State) async throws -> [Mutation] {
    if state.entries.contains(where: { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == id
    }) {
      return [.toolCallStatusUpdated(id: id, status: .errored)]
    }

    let toolName: String = {
      for entry in state.entries.reversed() {
        guard case let .message(m) = entry.payload else { continue }
        guard case let .assistant(a) = m else { continue }
        for block in a.content {
          guard case let .toolCall(callID, name, _) = block else { continue }
          if callID == id { return name }
        }
      }
      return "unknown"
    }()

    let now = Date()
    let repaired: Message = .toolResult(.init(
      toolCallId: id,
      toolName: toolName,
      content: [.text(WuhuToolRepairer.lostToolResultText)],
      details: .object([
        "wuhu_repair": .string("stale_tool_call"),
        "reason": .string("lost"),
      ]),
      isError: true,
      timestamp: now,
    ))

    let entryID = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(
      id: entryID,
      createdAt: now,
      payload: .message(.fromPi(repaired)),
      to: &nextSession,
    )

    return [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: id, status: .errored),
      .statusUpdated(.init(status: .running)),
    ]
  }

  func persist(from oldState: State, to newState: State) async throws -> [PersistedEvent] {
    try await store.persistLoopStateTransition(sessionID: sessionID, from: oldState, to: newState)
  }

  func hasWork(state: State) -> Bool {
    switch state.status.status {
    case .stopped:
      false
    case .running:
      true
    case .idle:
      false
    }
  }

  func needsInference(state: State) -> Bool {
    for entry in state.entries.reversed() {
      switch entry.payload {
      case let .message(m):
        switch m {
        case .toolResult:
          return true
        case .user:
          return true
        case .assistant:
          return false
        case .customMessage:
          continue
        case .unknown:
          continue
        }
      default:
        continue
      }
    }
    return false
  }

  // MARK: - Image blob hydration

  private func hydrateImageBlobs(in messages: [Message]) -> [Message] {
    messages.map { message in
      switch message {
      case var .user(u):
        u.content = u.content.map(hydrateBlock)
        return .user(u)
      case let .assistant(a):
        return .assistant(a)
      case var .toolResult(t):
        t.content = t.content.map(hydrateBlock)
        return .toolResult(t)
      }
    }
  }

  private func hydrateBlock(_ block: ContentBlock) -> ContentBlock {
    guard case let .image(img) = block, img.data.hasPrefix("blob://") else { return block }
    do {
      let base64 = try blobStore.resolveToBase64(uri: img.data)
      return .image(.init(data: base64, mimeType: img.mimeType))
    } catch {
      return .text(.init(text: "[Failed to load image: \(error)]"))
    }
  }

  private func applyModelSelection(_ selection: WuhuSessionSettings, state: State) async throws -> [Mutation] {
    let entryID = try await firstReservedEntryID()
    var nextSession = state.session
    let entry = appendEntry(
      id: entryID,
      createdAt: Date(),
      payload: .sessionSettings(selection),
      to: &nextSession,
    )
    nextSession.provider = selection.provider
    nextSession.model = selection.model

    let nextSettings = SessionSettingsSnapshot(
      effectiveModel: .init(provider: .init(rawValue: selection.provider.rawValue), id: selection.model),
      pendingModel: nil,
      effectiveReasoningEffort: selection.reasoningEffort,
      pendingReasoningEffort: nil,
    )

    return [
      .sessionUpdated(nextSession),
      .entryAppended(entry),
      .settingsUpdated(nextSettings),
      .statusUpdated(state.status),
    ]
  }

  private func enqueueUser(item: UserQueuePendingItem, lane: UserQueueLane, into state: State) -> UserQueueBackfill {
    var backfill = lane == .steer ? state.steer : state.followUp
    backfill.pending.append(item)
    backfill.pending.sort {
      if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
      return $0.id.rawValue < $1.id.rawValue
    }
    backfill.journal.append(.enqueued(lane: lane, item: item))
    backfill.cursor = advancedCursor(backfill.cursor, by: 1)
    return backfill
  }

  private func cancelUser(id: QueueItemID, lane: UserQueueLane, from state: State) throws -> UserQueueBackfill {
    var backfill = lane == .steer ? state.steer : state.followUp
    let before = backfill.pending.count
    backfill.pending.removeAll { $0.id == id }
    guard before != backfill.pending.count else {
      throw WuhuStoreError.sessionCorrupt("Queue item not found: \(id.rawValue)")
    }
    backfill.journal.append(.canceled(lane: lane, id: id, at: Date()))
    backfill.cursor = advancedCursor(backfill.cursor, by: 1)
    return backfill
  }

  private func enqueueSystem(item: SystemUrgentPendingItem, into state: State) -> SystemUrgentQueueBackfill {
    var backfill = state.systemUrgent
    backfill.pending.append(item)
    backfill.pending.sort {
      if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
      return $0.id.rawValue < $1.id.rawValue
    }
    backfill.journal.append(.enqueued(item: item))
    backfill.cursor = advancedCursor(backfill.cursor, by: 1)
    return backfill
  }

  private func setPendingModelSelection(_ selection: WuhuSessionSettings, from settings: SessionSettingsSnapshot) -> SessionSettingsSnapshot {
    .init(
      effectiveModel: settings.effectiveModel,
      pendingModel: .init(provider: .init(rawValue: selection.provider.rawValue), id: selection.model),
      effectiveReasoningEffort: settings.effectiveReasoningEffort,
      pendingReasoningEffort: selection.reasoningEffort,
    )
  }

  private func statusAfterUserCancel(from state: State, replacing backfill: UserQueueBackfill, lane: UserQueueLane) -> SessionExecutionStatus {
    var next = state
    apply(.userQueueUpdated(lane: lane, backfill: backfill), to: &next)
    if next.status.status == .stopped { return .stopped }
    return hasPendingWork(next) ? .running : .idle
  }

  private func statusAfterApplying(_ mutations: [Mutation], to state: State) -> SessionExecutionStatus {
    var next = state
    for mutation in mutations {
      apply(mutation, to: &next)
    }
    if next.status.status == .stopped { return .stopped }
    return hasPendingWork(next) ? .running : .idle
  }

  private func hasPendingWork(_ state: State) -> Bool {
    !state.systemUrgent.pending.isEmpty
      || !state.steer.pending.isEmpty
      || !state.followUp.pending.isEmpty
      || state.toolCallStatus.values.contains(where: { $0 == .pending || $0 == .started })
  }

  private func appendEntry(
    id: Int64,
    createdAt: Date,
    payload: WuhuEntryPayload,
    to session: inout WuhuSession,
  ) -> WuhuSessionEntry {
    let entry = WuhuSessionEntry(
      id: id,
      sessionID: session.id,
      parentEntryID: session.tailEntryID,
      createdAt: createdAt,
      payload: payload,
    )
    session.tailEntryID = id
    session.updatedAt = Date()
    return entry
  }

  private func materializedPayload(for item: UserQueuePendingItem) -> WuhuEntryPayload {
    let user = WuhuUserMessage(
      user: userString(item.message.author),
      content: item.message.content.toContentBlocks(),
      timestamp: item.enqueuedAt,
    )
    return .message(.user(user))
  }

  private func materializedPayload(for item: SystemUrgentPendingItem) -> WuhuEntryPayload {
    let custom = WuhuCustomMessage(
      customType: "wuhu_system_input_v1",
      content: item.input.content.toContentBlocks(),
      details: .object([
        "source": .string(systemSourceString(item.input.source)),
      ]),
      display: true,
      timestamp: item.enqueuedAt,
    )
    return .message(.customMessage(custom))
  }

  private func advancedCursor(_ cursor: QueueCursor, by count: Int) -> QueueCursor {
    let current = Int64(cursor.rawValue) ?? 0
    return .init(rawValue: "\(current + Int64(count))")
  }

  private func firstReservedEntryID() async throws -> Int64 {
    guard let id = try await store.reserveEntryIDs(count: 1).first else {
      throw WuhuStoreError.sessionCorrupt("Failed to reserve entry id")
    }
    return id
  }
}

private func makeRequestOptions(model: Model, settings: SessionSettingsSnapshot, userModelID: String? = nil) -> RequestOptions {
  var requestOptions = RequestOptions()

  let specLookupID = userModelID ?? model.id
  requestOptions.maxTokens = WuhuModelCatalog.defaultMaxTokens(for: specLookupID)

  if let effort = settings.effectiveReasoningEffort {
    requestOptions.reasoningEffort = effort
  } else if model.provider == .openai || model.provider == .openaiCodex,
            model.id.contains("gpt-5") || model.id.contains("codex")
  {
    requestOptions.reasoningEffort = .low
  }
  if model.provider == .anthropic {
    requestOptions.anthropicPromptCaching = .init(mode: .explicitBreakpoints)
    requestOptions.maxTokens = requestOptions.maxTokens ?? 4096
  }
  return requestOptions
}

private func mergeBetaFeatures(_ features: [String], into options: inout RequestOptions) {
  guard !features.isEmpty else { return }
  let existing = options.headers["anthropic-beta"] ?? ""
  var items = existing.isEmpty ? [] : existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  for feature in features where !items.contains(feature) {
    items.append(feature)
  }
  options.headers["anthropic-beta"] = items.joined(separator: ", ")
}

private func modelFromSettings(_ settings: SessionSettingsSnapshot) -> Model {
  let provider: Provider = switch settings.effectiveModel.provider.rawValue {
  case ProviderID.openai.rawValue:
    .openai
  case ProviderID.openaiCodex.rawValue:
    .openaiCodex
  case ProviderID.anthropic.rawValue:
    .anthropic
  default:
    .openai
  }
  return .init(id: settings.effectiveModel.id, provider: provider)
}

func providerBaseURL(for provider: Provider) -> URL? {
  let envVar: String? = switch provider {
  case .anthropic:
    ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
  case .openai, .openaiCodex:
    ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
  }
  guard let value = envVar, let url = URL(string: value) else { return nil }
  return url
}
