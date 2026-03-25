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
  case setCustomTitle(String?)
  case setArchived(Bool)
  case setCwd(String?)

  case setPendingModelSelection(WuhuSessionSettings)
  case applyModelSelection(WuhuSessionSettings)
  case applyPendingModelIfPossible
}

struct WuhuSessionToolCallStatusChange: Sendable, Hashable {
  var id: String
  var status: ToolCallStatus
}

struct WuhuSessionPersistenceDiff: Sendable {
  var appendedEntries: [WuhuSessionEntry]
  var systemJournalEntries: [SystemUrgentQueueJournalEntry]
  var steerJournalEntries: [UserQueueJournalEntry]
  var followUpJournalEntries: [UserQueueJournalEntry]
  var toolCallStatusChanges: [WuhuSessionToolCallStatusChange]
  var sessionMetadataChanged: Bool
  var settingsChanged: Bool
  var statusChanged: Bool
}

struct WuhuSessionLoopState: Sendable, Equatable {
  var session: WuhuSession
  var mounts: WuhuInterpretedMountState
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
      mounts: .init(),
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
  typealias PersistenceDiff = WuhuSessionPersistenceDiff
  typealias StreamAction = WuhuSessionStreamAction
  typealias ExternalAction = WuhuSessionExternalAction
  typealias ToolResult = AgentToolResult

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: WuhuSessionRuntimeConfig
  let blobStore: WuhuBlobStore
  let streamFn: StreamFn

  func loadState() async throws -> State {
    let parts = try await store.loadLoopStateParts(sessionID: sessionID)
    let interpretedMounts = interpretToolState(entries: parts.entries)
    var session = parts.session
    if let primaryMount = interpretedMounts.primaryMount {
      session.cwd = primaryMount.path
    }
    return .init(
      session: session,
      mounts: interpretedMounts,
      toolCallStatus: parts.toolCallStatus,
      entries: parts.entries,
      settings: parts.settings,
      status: parts.status,
      systemUrgent: parts.systemUrgent,
      steer: parts.steer,
      followUp: parts.followUp,
    )
  }

  func diff(from oldState: State, to newState: State) -> PersistenceDiff? {
    let appendedEntries = Array(newState.entries.dropFirst(oldState.entries.count))
    let systemJournalEntries = Array(newState.systemUrgent.journal.dropFirst(oldState.systemUrgent.journal.count))
    let steerJournalEntries = Array(newState.steer.journal.dropFirst(oldState.steer.journal.count))
    let followUpJournalEntries = Array(newState.followUp.journal.dropFirst(oldState.followUp.journal.count))

    let toolCallStatusChanges = newState.toolCallStatus.keys.sorted().compactMap { id -> WuhuSessionToolCallStatusChange? in
      let oldValue = oldState.toolCallStatus[id]
      let newValue = newState.toolCallStatus[id]
      guard oldValue != newValue, let newValue else { return nil }
      return .init(id: id, status: newValue)
    }

    let sessionMetadataChanged =
      oldState.session.customTitle != newState.session.customTitle
        || oldState.session.isArchived != newState.session.isArchived
        || oldState.session.cwd != newState.session.cwd
    let settingsChanged = oldState.settings != newState.settings
    let statusChanged = oldState.status != newState.status

    guard !appendedEntries.isEmpty
      || !systemJournalEntries.isEmpty
      || !steerJournalEntries.isEmpty
      || !followUpJournalEntries.isEmpty
      || !toolCallStatusChanges.isEmpty
      || sessionMetadataChanged
      || settingsChanged
      || statusChanged
    else { return nil }

    return .init(
      appendedEntries: appendedEntries,
      systemJournalEntries: systemJournalEntries,
      steerJournalEntries: steerJournalEntries,
      followUpJournalEntries: followUpJournalEntries,
      toolCallStatusChanges: toolCallStatusChanges,
      sessionMetadataChanged: sessionMetadataChanged,
      settingsChanged: settingsChanged,
      statusChanged: statusChanged,
    )
  }

  func persist(_ diff: PersistenceDiff, from oldState: State, to newState: State) async throws -> State {
    let patch = try await buildLoopPersistencePatch(diff: diff, oldState: oldState, newState: newState)
    let durable = try await store.persistLoopStatePatch(sessionID: sessionID, patch: patch)
    let interpretedMounts = interpretToolState(entries: durable.entries)
    var session = durable.session
    if let primaryMount = interpretedMounts.primaryMount {
      session.cwd = primaryMount.path
    }
    return .init(
      session: session,
      mounts: interpretedMounts,
      toolCallStatus: durable.toolCallStatus,
      entries: durable.entries,
      settings: durable.settings,
      status: durable.status,
      systemUrgent: durable.systemUrgent,
      steer: durable.steer,
      followUp: durable.followUp,
    )
  }

  func handle(_ action: ExternalAction, state: inout State) {
    switch action {
    case let .enqueueUser(id, message, lane):
      let item = UserQueuePendingItem(id: id, enqueuedAt: Date(), message: message)
      let backfill = enqueueUser(item: item, lane: lane, into: state)
      applyUserQueue(backfill, lane: lane, to: &state)
      state.status = .init(status: .running)

    case let .cancelUser(id, lane):
      guard let backfill = cancelUser(id: id, lane: lane, from: state) else { return }
      applyUserQueue(backfill, lane: lane, to: &state)
      state.status = .init(status: statusForOperationalState(state))

    case let .enqueueSystem(id, input, enqueuedAt):
      let item = SystemUrgentPendingItem(id: id, enqueuedAt: enqueuedAt, input: input)
      state.systemUrgent = enqueueSystem(item: item, into: state)
      state.status = .init(status: .running)

    case let .setCustomTitle(title):
      guard state.session.customTitle != title else { return }
      state.session.customTitle = title
      state.session.updatedAt = Date()

    case let .setArchived(isArchived):
      guard state.session.isArchived != isArchived else { return }
      state.session.isArchived = isArchived
      state.session.updatedAt = Date()

    case let .setCwd(cwd):
      guard state.session.cwd != cwd else { return }
      state.session.cwd = cwd
      state.session.updatedAt = Date()

    case let .setPendingModelSelection(selection):
      state.settings = setPendingModelSelection(selection, from: state.settings)

    case let .applyModelSelection(selection):
      applyModelSelection(selection, state: &state)

    case .applyPendingModelIfPossible:
      guard let pending = state.settings.pendingModel else { return }
      guard state.status.status == .idle, !hasPendingWork(state), !needsInference(state: state) else { return }
      let selection = WuhuSessionSettings(
        provider: WuhuProvider(rawValue: pending.provider.rawValue) ?? .openai,
        model: pending.id,
        reasoningEffort: state.settings.pendingReasoningEffort,
      )
      applyModelSelection(selection, state: &state)
    }
  }

  @discardableResult
  func drainInterruptItems(state: inout State) -> Bool {
    if state.status.status == .stopped { return false }

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

    guard !candidates.isEmpty else { return false }

    state.systemUrgent.pending = []
    state.steer.pending = []

    for candidate in candidates {
      switch candidate.kind {
      case let .system(item):
        let entry = appendEntry(
          createdAt: item.enqueuedAt,
          payload: materializedPayload(for: item),
          to: &state,
        )
        state.systemUrgent.journal.append(.materialized(
          id: item.id,
          transcriptEntryID: .init(rawValue: "\(entry.id)"),
          at: Date(),
        ))
      case let .steer(item):
        let entry = appendEntry(
          createdAt: item.enqueuedAt,
          payload: materializedPayload(for: item),
          to: &state,
        )
        state.steer.journal.append(.materialized(
          lane: .steer,
          id: item.id,
          transcriptEntryID: .init(rawValue: "\(entry.id)"),
          at: Date(),
        ))
      }
    }

    state.systemUrgent.cursor = advancedCursor(
      state.systemUrgent.cursor,
      by: candidates.count { if case .system = $0.kind { true } else { false } },
    )
    state.steer.cursor = advancedCursor(
      state.steer.cursor,
      by: candidates.count { if case .steer = $0.kind { true } else { false } },
    )
    state.status = .init(status: state.status.status == .stopped ? .stopped : .running)
    return true
  }

  @discardableResult
  func drainTurnItems(state: inout State) -> Bool {
    if state.status.status == .stopped { return false }
    guard !state.followUp.pending.isEmpty else { return false }

    let items = state.followUp.pending.sorted {
      if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
      return $0.id.rawValue < $1.id.rawValue
    }

    state.followUp.pending = []

    for item in items {
      let entry = appendEntry(
        createdAt: item.enqueuedAt,
        payload: materializedPayload(for: item),
        to: &state,
      )
      state.followUp.journal.append(.materialized(
        lane: .followUp,
        id: item.id,
        transcriptEntryID: .init(rawValue: "\(entry.id)"),
        at: Date(),
      ))
    }
    state.followUp.cursor = advancedCursor(state.followUp.cursor, by: items.count)
    state.status = .init(status: state.status.status == .stopped ? .stopped : .running)
    return true
  }

  func buildContext(state: State) -> Context {
    let header = (try? WuhuPromptPreparation.extractHeader(from: state.entries, sessionID: sessionID.rawValue))
    var systemPrompt = header?.systemPrompt ?? ""
    if let cwd = state.session.cwd {
      systemPrompt += "\n\nWorking directory: \(cwd)\nAll relative paths are resolved from this directory."
    }
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let hydrated = hydrateImageBlobs(in: messages)
    return Context(systemPrompt: systemPrompt, messages: hydrated, tools: [])
  }

  func infer(context: Context, stream: AgentStreamSink<StreamAction>) async throws -> AssistantMessage {
    let session = try await store.getSession(id: sessionID.rawValue)
    let tools = await runtimeConfig.tools()

    let resolved = WuhuModelCatalog.resolveAlias(session.model)
    let provider = session.provider.piProvider
    let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
    var requestOptions = try await makeRequestOptions(model: apiModel, settings: store.loadSettingsSnapshot(sessionID: sessionID), userModelID: session.model)
    requestOptions.sessionId = sessionID.rawValue
    mergeBetaFeatures(resolved.betaFeatures, into: &requestOptions)

    let effectiveContext = Context(
      systemPrompt: context.systemPrompt,
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

  func persistAssistantEntry(_ message: AssistantMessage, state: inout State) {
    _ = appendEntry(
      createdAt: message.timestamp,
      payload: .message(.fromPi(.assistant(message))),
      to: &state,
    )

    let calls = message.content.compactMap { block -> ToolCall? in
      if case let .toolCall(call) = block { return call }
      return nil
    }
    for call in calls {
      state.toolCallStatus[call.id] = .pending
    }
    state.status = .init(status: statusForOperationalState(state))
  }

  func toolWillExecute(_ call: ToolCall, state: inout State) {
    state.toolCallStatus[call.id] = .started
    state.status = .init(status: .running)
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

  func toolDidExecute(_ call: ToolCall, result: ToolResult, state: inout State) {
    let now = Date()
    let toolResultMessage = WuhuToolResultMessage(
      toolCallId: call.id,
      toolName: call.name,
      content: result.content.map(WuhuContentBlock.fromPi),
      details: result.details,
      isError: false,
      timestamp: now,
    )

    _ = appendEntry(
      createdAt: now,
      payload: .message(.toolResult(toolResultMessage)),
      to: &state,
    )

    for effect in result.effects {
      _ = appendEntry(
        createdAt: now,
        payload: .knownCustom(effect),
        to: &state,
      )
      applyKnownCustomEntry(effect, timestamp: now, state: &state)
    }

    state.toolCallStatus[call.id] = .completed
    state.status = .init(status: statusForOperationalState(state))
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state: inout State) {
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

    _ = appendEntry(
      createdAt: now,
      payload: .message(.fromPi(toolResult)),
      to: &state,
    )
    state.toolCallStatus[call.id] = .errored
    state.status = .init(status: statusForOperationalState(state))
  }

  func shouldCompact(state: State) -> Bool {
    let model = modelFromSettings(state.settings)
    let settings = WuhuCompactionSettings.load(model: model)
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let estimate = WuhuCompactionEngine.estimateContextTokens(messages: messages)
    return WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }

  func performCompaction(state: State) async throws -> State {
    let session = state.session
    let provider = session.provider.piProvider
    let settingsModel = Model(id: session.model, provider: provider)
    let settings = WuhuCompactionSettings.load(model: settingsModel)

    guard let prep = WuhuCompactionEngine.prepareCompaction(transcript: state.entries, settings: settings) else {
      return state
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

    var next = state
    _ = appendEntry(createdAt: Date(), payload: payload, to: &next)
    return next
  }

  func staleToolCallIDs(in state: State) -> [String] {
    var finished: Set<String> = []
    for entry in state.entries {
      guard case let .message(message) = entry.payload else { continue }
      guard case let .toolResult(toolResult) = message else { continue }
      finished.insert(toolResult.toolCallId)
    }

    return state.toolCallStatus.compactMap { id, status in
      guard status == .started || status == .pending else { return nil }
      return finished.contains(id) ? nil : id
    }.sorted()
  }

  func recoverStaleToolCall(id: String, state: inout State) {
    if state.entries.contains(where: { entry in
      guard case let .message(message) = entry.payload else { return false }
      guard case let .toolResult(toolResult) = message else { return false }
      return toolResult.toolCallId == id
    }) {
      state.toolCallStatus[id] = .errored
      state.status = .init(status: statusForOperationalState(state))
      return
    }

    let toolName: String = {
      for entry in state.entries.reversed() {
        guard case let .message(message) = entry.payload else { continue }
        guard case let .assistant(assistant) = message else { continue }
        for block in assistant.content {
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

    _ = appendEntry(
      createdAt: now,
      payload: .message(.fromPi(repaired)),
      to: &state,
    )
    state.toolCallStatus[id] = .errored
    state.status = .init(status: statusForOperationalState(state))
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
      case let .message(message):
        switch message {
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

  private func hydrateImageBlobs(in messages: [Message]) -> [Message] {
    messages.map { message in
      switch message {
      case var .user(user):
        user.content = user.content.map(hydrateBlock)
        return .user(user)
      case let .assistant(assistant):
        return .assistant(assistant)
      case var .toolResult(toolResult):
        toolResult.content = toolResult.content.map(hydrateBlock)
        return .toolResult(toolResult)
      }
    }
  }

  private func hydrateBlock(_ block: ContentBlock) -> ContentBlock {
    guard case let .image(image) = block, image.data.hasPrefix("blob://") else { return block }
    do {
      let base64 = try blobStore.resolveToBase64(uri: image.data)
      return .image(.init(data: base64, mimeType: image.mimeType))
    } catch {
      return .text(.init(text: "[Failed to load image: \(error)]"))
    }
  }

  private func pendingModelSelectionUpdate(
    diff: PersistenceDiff,
    oldState: State,
    newState: State,
    standaloneEntries: [WuhuSessionEntry],
  ) -> WuhuSessionSettings? {
    guard diff.settingsChanged else { return nil }
    guard !standaloneEntries.contains(where: isSessionSettingsEntry(_:)) else { return nil }
    guard oldState.settings.pendingModel != newState.settings.pendingModel
      || oldState.settings.pendingReasoningEffort != newState.settings.pendingReasoningEffort
    else { return nil }
    guard let pending = newState.settings.pendingModel else { return nil }

    return WuhuSessionSettings(
      provider: WuhuProvider(rawValue: pending.provider.rawValue) ?? .openai,
      model: pending.id,
      reasoningEffort: newState.settings.pendingReasoningEffort,
    )
  }

  private func buildLoopPersistencePatch(
    diff: PersistenceDiff,
    oldState: State,
    newState: State,
  ) async throws -> SQLiteSessionStore.LoopPersistencePatch {
    let materializedEntryIDs = try materializedTranscriptEntryIDs(diff)
    let standaloneEntries = diff.appendedEntries.filter { !materializedEntryIDs.contains($0.id) }
    let materializationSources = try materializationSources(diff: diff, oldState: oldState)
    let transcriptAppends = try await persistedTranscriptAppendOperations(
      diff.appendedEntries,
      materializationSources: materializationSources,
    )

    let pendingModelSelection = pendingModelSelectionUpdate(
      diff: diff,
      oldState: oldState,
      newState: newState,
      standaloneEntries: standaloneEntries,
    )
    let sessionMetadata: SQLiteSessionStore.SessionMetadataUpdate? = if diff.sessionMetadataChanged {
      SQLiteSessionStore.SessionMetadataUpdate(
        customTitle: newState.session.customTitle,
        isArchived: newState.session.isArchived,
        cwd: newState.session.cwd,
      )
    } else {
      nil
    }

    return .init(
      pendingModelSelection: pendingModelSelection,
      systemQueueEnqueues: systemQueueEnqueueOperations(diff: diff, newState: newState),
      userQueueOperations: userQueueOperations(diff: diff, oldState: oldState, newState: newState),
      transcriptAppends: transcriptAppends,
      toolCallStatusChanges: diff.toolCallStatusChanges.map { .init(id: $0.id, status: $0.status) },
      sessionMetadata: sessionMetadata,
      executionStatus: diff.statusChanged ? newState.status.status : nil,
    )
  }

  private func systemQueueEnqueueOperations(
    diff: PersistenceDiff,
    newState: State,
  ) -> [SQLiteSessionStore.SystemQueueEnqueueOperation] {
    let pendingIDs = Set(newState.systemUrgent.pending.map(\.id))
    return diff.systemJournalEntries.compactMap { entry in
      guard case let .enqueued(item) = entry else { return nil }
      return .init(item: item, insertPending: pendingIDs.contains(item.id))
    }
  }

  private func userQueueOperations(
    diff: PersistenceDiff,
    oldState: State,
    newState: State,
  ) -> [SQLiteSessionStore.UserQueueOperation] {
    let oldSteerIDs = Set(oldState.steer.pending.map(\.id))
    let oldFollowUpIDs = Set(oldState.followUp.pending.map(\.id))
    let newSteerIDs = Set(newState.steer.pending.map(\.id))
    let newFollowUpIDs = Set(newState.followUp.pending.map(\.id))

    return queueOperations(
      diff.steerJournalEntries,
      lane: .steer,
      oldPendingIDs: oldSteerIDs,
      newPendingIDs: newSteerIDs,
    ) + queueOperations(
      diff.followUpJournalEntries,
      lane: .followUp,
      oldPendingIDs: oldFollowUpIDs,
      newPendingIDs: newFollowUpIDs,
    )
  }

  private func queueOperations(
    _ entries: [UserQueueJournalEntry],
    lane: UserQueueLane,
    oldPendingIDs: Set<QueueItemID>,
    newPendingIDs: Set<QueueItemID>,
  ) -> [SQLiteSessionStore.UserQueueOperation] {
    entries.compactMap { entry in
      switch entry {
      case let .enqueued(_, item):
        .init(lane: lane, kind: .enqueue(item: item, insertPending: newPendingIDs.contains(item.id)))
      case let .canceled(_, id, at):
        .init(lane: lane, kind: .cancel(id: id, deletePending: oldPendingIDs.contains(id), createdAt: at))
      case .materialized:
        nil
      }
    }
  }

  private func persistedTranscriptAppendOperations(
    _ entries: [WuhuSessionEntry],
    materializationSources: [Int64: SQLiteSessionStore.TranscriptAppendOperation.Source],
  ) async throws -> [SQLiteSessionStore.TranscriptAppendOperation] {
    var operations: [SQLiteSessionStore.TranscriptAppendOperation] = []
    operations.reserveCapacity(entries.count)

    var remainingSources = materializationSources
    for entry in entries {
      let payload = try await persistedPayload(entry.payload)
      operations.append(
        .init(
          createdAt: entry.createdAt,
          payload: payload,
          source: remainingSources.removeValue(forKey: entry.id),
        ),
      )
    }

    guard remainingSources.isEmpty else {
      let ids = remainingSources.keys.sorted().map(String.init).joined(separator: ", ")
      throw WuhuStoreError.sessionCorrupt("Missing transcript entries for materializations: \(ids)")
    }

    return operations
  }

  private func materializationSources(
    diff: PersistenceDiff,
    oldState: State,
  ) throws -> [Int64: SQLiteSessionStore.TranscriptAppendOperation.Source] {
    var sources: [Int64: SQLiteSessionStore.TranscriptAppendOperation.Source] = [:]

    let oldSystemIDs = Set(oldState.systemUrgent.pending.map(\.id))
    let oldSteerIDs = Set(oldState.steer.pending.map(\.id))
    let oldFollowUpIDs = Set(oldState.followUp.pending.map(\.id))

    try addMaterializationSources(
      from: diff.systemJournalEntries,
      oldPendingIDs: oldSystemIDs,
      into: &sources,
    )
    try addMaterializationSources(
      from: diff.steerJournalEntries,
      lane: .steer,
      oldPendingIDs: oldSteerIDs,
      into: &sources,
    )
    try addMaterializationSources(
      from: diff.followUpJournalEntries,
      lane: .followUp,
      oldPendingIDs: oldFollowUpIDs,
      into: &sources,
    )

    return sources
  }

  private func addMaterializationSources(
    from entries: [SystemUrgentQueueJournalEntry],
    oldPendingIDs: Set<QueueItemID>,
    into sources: inout [Int64: SQLiteSessionStore.TranscriptAppendOperation.Source],
  ) throws {
    for entry in entries {
      guard case let .materialized(id, transcriptEntryID, at) = entry else { continue }
      guard let tempID = Int64(transcriptEntryID.rawValue) else {
        throw WuhuStoreError.sessionCorrupt("Invalid transcript entry id: \(transcriptEntryID.rawValue)")
      }
      guard sources[tempID] == nil else {
        throw WuhuStoreError.sessionCorrupt("Duplicate transcript materialization for entry id \(tempID)")
      }
      sources[tempID] = .systemMaterialization(
        id: id,
        deletePending: oldPendingIDs.contains(id),
        journalCreatedAt: at,
      )
    }
  }

  private func addMaterializationSources(
    from entries: [UserQueueJournalEntry],
    lane: UserQueueLane,
    oldPendingIDs: Set<QueueItemID>,
    into sources: inout [Int64: SQLiteSessionStore.TranscriptAppendOperation.Source],
  ) throws {
    for entry in entries {
      guard case let .materialized(_, id, transcriptEntryID, at) = entry else { continue }
      guard let tempID = Int64(transcriptEntryID.rawValue) else {
        throw WuhuStoreError.sessionCorrupt("Invalid transcript entry id: \(transcriptEntryID.rawValue)")
      }
      guard sources[tempID] == nil else {
        throw WuhuStoreError.sessionCorrupt("Duplicate transcript materialization for entry id \(tempID)")
      }
      sources[tempID] = .userMaterialization(
        lane: lane,
        id: id,
        deletePending: oldPendingIDs.contains(id),
        journalCreatedAt: at,
      )
    }
  }

  private func materializedTranscriptEntryIDs(_ diff: PersistenceDiff) throws -> Set<Int64> {
    var ids: Set<Int64> = []
    try collectMaterializedTranscriptEntryIDs(from: diff.systemJournalEntries, into: &ids)
    try collectMaterializedTranscriptEntryIDs(from: diff.steerJournalEntries, into: &ids)
    try collectMaterializedTranscriptEntryIDs(from: diff.followUpJournalEntries, into: &ids)
    return ids
  }

  private func collectMaterializedTranscriptEntryIDs(
    from entries: [SystemUrgentQueueJournalEntry],
    into ids: inout Set<Int64>,
  ) throws {
    for entry in entries {
      guard case let .materialized(_, transcriptEntryID, _) = entry else { continue }
      guard let id = Int64(transcriptEntryID.rawValue) else {
        throw WuhuStoreError.sessionCorrupt("Invalid transcript entry id: \(transcriptEntryID.rawValue)")
      }
      ids.insert(id)
    }
  }

  private func collectMaterializedTranscriptEntryIDs(
    from entries: [UserQueueJournalEntry],
    into ids: inout Set<Int64>,
  ) throws {
    for entry in entries {
      guard case let .materialized(_, _, transcriptEntryID, _) = entry else { continue }
      guard let id = Int64(transcriptEntryID.rawValue) else {
        throw WuhuStoreError.sessionCorrupt("Invalid transcript entry id: \(transcriptEntryID.rawValue)")
      }
      ids.insert(id)
    }
  }

  private func isSessionSettingsEntry(_ entry: WuhuSessionEntry) -> Bool {
    if case .sessionSettings = entry.payload { return true }
    return false
  }

  private func applyModelSelection(_ selection: WuhuSessionSettings, state: inout State) {
    _ = appendEntry(
      createdAt: Date(),
      payload: .sessionSettings(selection),
      to: &state,
    )
    state.session.provider = selection.provider
    state.session.model = selection.model
    state.settings = .init(
      effectiveModel: .init(provider: .init(rawValue: selection.provider.rawValue), id: selection.model),
      pendingModel: nil,
      effectiveReasoningEffort: selection.reasoningEffort,
      pendingReasoningEffort: nil,
    )
  }

  private func applyUserQueue(_ backfill: UserQueueBackfill, lane: UserQueueLane, to state: inout State) {
    switch lane {
    case .steer:
      state.steer = backfill
    case .followUp:
      state.followUp = backfill
    }
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

  private func cancelUser(id: QueueItemID, lane: UserQueueLane, from state: State) -> UserQueueBackfill? {
    var backfill = lane == .steer ? state.steer : state.followUp
    let before = backfill.pending.count
    backfill.pending.removeAll { $0.id == id }
    guard before != backfill.pending.count else { return nil }
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

  private func statusForOperationalState(_ state: State) -> SessionExecutionStatus {
    if state.status.status == .stopped { return .stopped }
    return hasPendingWork(state) || needsInference(state: state) ? .running : .idle
  }

  private func hasPendingWork(_ state: State) -> Bool {
    !state.systemUrgent.pending.isEmpty
      || !state.steer.pending.isEmpty
      || !state.followUp.pending.isEmpty
      || state.toolCallStatus.values.contains(where: { $0 == .pending || $0 == .started })
  }

  private func appendEntry(
    createdAt: Date,
    payload: WuhuEntryPayload,
    to state: inout State,
  ) -> WuhuSessionEntry {
    let id = nextEntryID(in: state)
    let entry = WuhuSessionEntry(
      id: id,
      sessionID: state.session.id,
      parentEntryID: state.session.tailEntryID,
      createdAt: createdAt,
      payload: payload,
    )
    state.session.tailEntryID = id
    state.session.updatedAt = Date()
    state.entries.append(entry)
    return entry
  }

  private func nextEntryID(in state: State) -> Int64 {
    max(state.session.tailEntryID, state.entries.last?.id ?? state.session.tailEntryID) + 1
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

  private func persistedPayload(_ payload: WuhuEntryPayload) async throws -> WuhuEntryPayload {
    switch payload {
    case let .message(message):
      try await .message(persistedMessage(message))
    default:
      payload
    }
  }

  private func persistedMessage(_ message: WuhuPersistedMessage) async throws -> WuhuPersistedMessage {
    switch message {
    case var .user(user):
      user.content = try await persistedBlocks(user.content)
      return .user(user)
    case var .assistant(assistant):
      assistant.content = try await persistedBlocks(assistant.content)
      return .assistant(assistant)
    case var .toolResult(toolResult):
      toolResult.content = try await persistedBlocks(toolResult.content)
      return .toolResult(toolResult)
    case var .customMessage(custom):
      custom.content = try await persistedBlocks(custom.content)
      return .customMessage(custom)
    case .unknown:
      return message
    }
  }

  private func persistedBlocks(_ blocks: [WuhuContentBlock]) async throws -> [WuhuContentBlock] {
    var persisted: [WuhuContentBlock] = []
    persisted.reserveCapacity(blocks.count)
    for block in blocks {
      let persistedBlock = try await persistedBlock(block)
      persisted.append(persistedBlock)
    }
    return persisted
  }

  private func persistedBlock(_ block: WuhuContentBlock) async throws -> WuhuContentBlock {
    guard case let .image(blobURI, mimeType) = block, !blobURI.hasPrefix("blob://") else {
      return block
    }
    guard let rawData = Data(base64Encoded: blobURI) else {
      return block
    }
    let uri = try blobStore.store(sessionID: sessionID.rawValue, data: rawData, mimeType: mimeType)
    return .image(blobURI: uri, mimeType: mimeType)
  }

  private func interpretToolState(entries: [WuhuSessionEntry]) -> WuhuInterpretedMountState {
    var mounts = WuhuInterpretedMountState()
    for entry in entries {
      guard let knownCustom = entry.payload.knownCustomEntry else { continue }
      applyKnownCustomEntry(knownCustom, timestamp: entry.createdAt, state: &mounts)
    }
    return mounts
  }

  private func applyKnownCustomEntry(
    _ effect: WuhuKnownCustomEntry,
    timestamp: Date,
    state: inout State,
  ) {
    applyKnownCustomEntry(effect, timestamp: timestamp, state: &state.mounts)

    if let primaryMount = state.mounts.primaryMount {
      state.session.cwd = primaryMount.path
      state.session.updatedAt = timestamp
    }
  }

  private func applyKnownCustomEntry(
    _ effect: WuhuKnownCustomEntry,
    timestamp _: Date,
    state: inout WuhuInterpretedMountState,
  ) {
    switch effect {
    case let .mountDeclared(mount):
      state.apply(mount)
    case .mountContext, .agentsContext, .skillsContext, .llmRetry, .llmGiveUp:
      break
    }
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
