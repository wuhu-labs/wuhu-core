import Foundation
import PiAI
import WuhuAPI

enum WuhuSessionStreamAction: Sendable, Hashable {
  case assistantTextDelta(String)
}

enum WuhuSessionExternalAction: Sendable, Hashable {
  case enqueueUser(id: QueueItemID, message: QueuedUserMessage, lane: UserQueueLane)
  case cancelUser(id: QueueItemID, lane: UserQueueLane)
  case enqueueSystem(id: QueueItemID, input: SystemUrgentInput, enqueuedAt: Date)
  case deliverBashResult(toolCallID: String, result: BashResult)
  case heartbeatToolCall(id: String)

  case setPendingModelSelection(WuhuSessionSettings)
  case applyModelSelection(WuhuSessionSettings)
  case applyPendingModelIfPossible
}

enum WuhuSessionCommittedAction: Sendable, Hashable {
  case sessionUpdated(WuhuSession)
  case entryAppended(WuhuSessionEntry)
  case toolCallStatusUpdated(id: String, record: ToolCallRecord)
  case systemQueueUpdated(SystemUrgentQueueBackfill)
  case userQueueUpdated(lane: UserQueueLane, backfill: UserQueueBackfill)
  case settingsUpdated(SessionSettingsSnapshot)
  case statusUpdated(SessionStatusSnapshot)
}

struct WuhuSessionLoopState: Sendable, Equatable {
  var toolCallStatus: [String: ToolCallRecord]
  var entries: [WuhuSessionEntry]
  var settings: SessionSettingsSnapshot
  var status: SessionStatusSnapshot
  var systemUrgent: SystemUrgentQueueBackfill
  var steer: UserQueueBackfill
  var followUp: UserQueueBackfill

  static var empty: WuhuSessionLoopState {
    .init(
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
  typealias CommittedAction = WuhuSessionCommittedAction
  typealias StreamAction = WuhuSessionStreamAction
  typealias ExternalAction = WuhuSessionExternalAction
  typealias ToolResult = AgentToolResult

  static let staleToolCallDeadline: TimeInterval = 60

  static var emptyState: WuhuSessionLoopState {
    .empty
  }

  let sessionID: SessionID
  let store: SQLiteSessionStore
  let runtimeConfig: WuhuSessionRuntimeConfig
  let blobStore: WuhuBlobStore

  func loadState() async throws -> State {
    let parts = try await store.loadLoopStateParts(sessionID: sessionID)
    return .init(
      toolCallStatus: parts.toolCallStatus,
      entries: parts.entries,
      settings: parts.settings,
      status: parts.status,
      systemUrgent: parts.systemUrgent,
      steer: parts.steer,
      followUp: parts.followUp,
    )
  }

  func apply(_ action: CommittedAction, to state: inout State) {
    switch action {
    case let .sessionUpdated(session):
      _ = session

    case let .entryAppended(entry):
      state.entries.append(entry)

    case let .toolCallStatusUpdated(id, record):
      state.toolCallStatus[id] = record

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

  func handle(_ action: ExternalAction, state: State) async throws -> [CommittedAction] {
    switch action {
    case let .enqueueUser(id, message, lane):
      _ = try await store.enqueueUserMessage(sessionID: sessionID, id: id, message: message, lane: lane)
      let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(status),
      ]

    case let .cancelUser(id, lane):
      try await store.cancelUserMessage(sessionID: sessionID, id: id, lane: lane)
      let backfill = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: lane)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .userQueueUpdated(lane: lane, backfill: backfill),
        .statusUpdated(status),
      ]

    case let .enqueueSystem(id, input, enqueuedAt):
      _ = try await store.enqueueSystemInput(sessionID: sessionID, id: id, input: input, enqueuedAt: enqueuedAt)
      let backfill = try await store.loadSystemQueueBackfill(sessionID: sessionID)
      let status = try await store.loadStatusSnapshot(sessionID: sessionID)
      return [
        .systemQueueUpdated(backfill),
        .statusUpdated(status),
      ]

    case let .deliverBashResult(toolCallID, result):
      return try await persistDeliveredBashResult(toolCallID: toolCallID, result: result, state: state)

    case let .heartbeatToolCall(id):
      guard let touched = try await store.touchToolCallStatus(sessionID: sessionID, id: id) else {
        return []
      }
      return [.toolCallStatusUpdated(id: touched.id, record: touched.record)]

    case let .setPendingModelSelection(selection):
      let settings = try await store.setPendingModelSelection(sessionID: sessionID, selection: selection)
      return [.settingsUpdated(settings)]

    case let .applyModelSelection(selection):
      let result = try await store.applyModelSelection(sessionID: sessionID, selection: selection)
      var actions: [CommittedAction] = [
        .sessionUpdated(result.session),
        .entryAppended(result.entry),
        .settingsUpdated(result.settings),
      ]
      try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
      return actions

    case .applyPendingModelIfPossible:
      guard let result = try await store.applyPendingModelIfPossible(sessionID: sessionID) else {
        return try await [.settingsUpdated(store.loadSettingsSnapshot(sessionID: sessionID))]
      }
      return [
        .sessionUpdated(result.session),
        .entryAppended(result.entry),
        .settingsUpdated(result.settings),
      ]
    }
  }

  func drainInterruptItems(state: State) async throws -> [CommittedAction] {
    if state.status.status == .stopped { return [] }
    let drained = try await store.drainInterruptCheckpoint(sessionID: sessionID)
    guard drained.didDrain else { return [] }
    var actions: [CommittedAction] = []
    actions.append(.sessionUpdated(drained.session))
    for entry in drained.entries {
      actions.append(.entryAppended(entry))
    }
    actions.append(.systemQueueUpdated(drained.systemUrgent))
    actions.append(.userQueueUpdated(lane: .steer, backfill: drained.steer))
    try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
    return actions
  }

  func drainTurnItems(state: State) async throws -> [CommittedAction] {
    if state.status.status == .stopped { return [] }
    let drained = try await store.drainTurnBoundary(sessionID: sessionID)
    guard drained.didDrain else { return [] }
    var actions: [CommittedAction] = []
    actions.append(.sessionUpdated(drained.session))
    for entry in drained.entries {
      actions.append(.entryAppended(entry))
    }
    actions.append(.userQueueUpdated(lane: .followUp, backfill: drained.followUp))
    try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
    return actions
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
    let streamFn = await runtimeConfig.streamFn()

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
    throw PiAIError.unsupported("No model output")
  }

  func persistAssistantEntry(_ message: AssistantMessage, state _: State) async throws -> [CommittedAction] {
    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(.assistant(message))),
      createdAt: message.timestamp,
    )

    var actions: [CommittedAction] = [
      .sessionUpdated(session),
      .entryAppended(entry),
    ]

    let calls = message.content.compactMap { block -> ToolCall? in
      if case let .toolCall(c) = block { return c }
      return nil
    }
    if !calls.isEmpty {
      let updates = try await store.upsertToolCallStatuses(sessionID: sessionID, calls: calls, status: .pending)
      for update in updates {
        actions.append(.toolCallStatusUpdated(id: update.id, record: update.record))
      }
    }

    try await actions.append(.statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)))
    return actions
  }

  func toolWillExecute(_ call: ToolCall, state _: State) async throws -> [CommittedAction] {
    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .started)
    return try await [
      .toolCallStatusUpdated(id: updated.id, record: updated.record),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
  }

  func executeToolCall(_ call: ToolCall) async throws -> ToolResult {
    let tools = await runtimeConfig.tools()
    guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
      throw PiAIError.unsupported("Unknown tool: \(call.name)")
    }
    return try await tool.execute(toolCallId: call.id, args: call.arguments)
  }

  func appendText(_ text: String, to result: AgentToolResult) -> AgentToolResult {
    var copy = result
    copy.content.append(.text(text))
    return copy
  }

  func toolDidExecute(_ call: ToolCall, result: ToolResult, state _: State) async throws -> [CommittedAction] {
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

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.toolResult(toolResultMessage)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .completed)
    return try await [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, record: updated.record),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
  }

  func toolDidFail(_ call: ToolCall, error: any Error, state _: State) async throws -> [CommittedAction] {
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

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(toolResult)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: call.id, status: .errored)
    return try await [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, record: updated.record),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
  }

  func pendingToolCalls(in state: State) -> [ToolCall] {
    let pendingIDs = state.toolCallStatus.compactMap { id, record in
      record.status == .pending ? id : nil
    }
    guard !pendingIDs.isEmpty else { return [] }

    let pendingSet = Set(pendingIDs)
    var calls: [ToolCall] = []
    for entry in state.entries.reversed() {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .assistant(a) = m else { continue }
      for block in a.content {
        guard case let .toolCall(id, name, arguments) = block else { continue }
        if pendingSet.contains(id) {
          calls.append(ToolCall(id: id, name: name, arguments: arguments))
        }
      }
    }
    return calls
  }

  func shouldCompact(state: State) -> Bool {
    let model = modelFromSettings(state.settings)
    let settings = WuhuCompactionSettings.load(model: model)
    let messages = WuhuPromptPreparation.extractContextMessages(from: state.entries)
    let estimate = WuhuCompactionEngine.estimateContextTokens(messages: messages)
    return WuhuCompactionEngine.shouldCompact(contextTokens: estimate.tokens, settings: settings)
  }

  func performCompaction(state: State) async throws -> [CommittedAction] {
    let session = try await store.getSession(id: sessionID.rawValue)
    let provider = session.provider.piProvider
    let settingsModel = Model(id: session.model, provider: provider)
    let settings = WuhuCompactionSettings.load(model: settingsModel)

    guard let prep = WuhuCompactionEngine.prepareCompaction(transcript: state.entries, settings: settings) else {
      return []
    }

    let resolved = WuhuModelCatalog.resolveAlias(session.model)
    let apiModel = Model(id: resolved.apiModelID, provider: provider, baseURL: providerBaseURL(for: provider))
    let streamFn = await runtimeConfig.streamFn()
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

    let (_, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: payload,
      createdAt: Date(),
    )

    return try await [
      .entryAppended(entry),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
  }

  func staleToolCallIDs(in state: State) -> [String] {
    let finished = finishedToolCallIDs(in: state.entries)
    let now = Date()

    return state.toolCallStatus.compactMap { id, record in
      guard record.status == .started else { return nil }
      guard !finished.contains(id) else { return nil }
      guard now.timeIntervalSince(record.updatedAt) > Self.staleToolCallDeadline else { return nil }
      return id
    }.sorted()
  }

  func recoverStaleToolCall(id: String, state: State) async throws -> [CommittedAction] {
    if state.entries.contains(where: { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == id
    }) {
      let updated = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
      return [.toolCallStatusUpdated(id: updated.id, record: updated.record)]
    }

    let toolName = toolName(for: id, in: state.entries) ?? "unknown"
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

    let (session, entry) = try await store.appendEntryWithSession(
      sessionID: sessionID,
      payload: .message(.fromPi(repaired)),
      createdAt: now,
    )

    let updated = try await store.setToolCallStatus(sessionID: sessionID, id: id, status: .errored)
    return try await [
      .sessionUpdated(session),
      .entryAppended(entry),
      .toolCallStatusUpdated(id: updated.id, record: updated.record),
      .statusUpdated(store.loadStatusSnapshot(sessionID: sessionID)),
    ]
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
    let finished = finishedToolCallIDs(in: state.entries)
    let hasUnresolvedTools = state.toolCallStatus.contains { id, record in
      (record.status == .pending || record.status == .started) && !finished.contains(id)
    }
    if hasUnresolvedTools { return false }

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
        case let .customMessage(custom):
          if custom.customType == "wuhu_system_input_v1" {
            return true
          }
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

  private func finishedToolCallIDs(in entries: [WuhuSessionEntry]) -> Set<String> {
    var finished: Set<String> = []
    for entry in entries {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .toolResult(t) = m else { continue }
      finished.insert(t.toolCallId)
    }
    return finished
  }

  private func toolName(for id: String, in entries: [WuhuSessionEntry]) -> String? {
    for entry in entries.reversed() {
      guard case let .message(m) = entry.payload else { continue }
      guard case let .assistant(a) = m else { continue }
      for block in a.content {
        guard case let .toolCall(callID, name, _) = block else { continue }
        if callID == id { return name }
      }
    }
    return nil
  }

  private func persistDeliveredBashResult(toolCallID: String, result: BashResult, state: State) async throws -> [CommittedAction] {
    if state.entries.contains(where: { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == toolCallID
    }) {
      return []
    }

    let bashCall = ToolCall(id: toolCallID, name: toolName(for: toolCallID, in: state.entries) ?? "bash", arguments: .object([:]))

    do {
      let formatted = try formatBashToolResult(result)
      return try await toolDidExecute(bashCall, result: formatted, state: state)
    } catch {
      return try await toolDidFail(bashCall, error: error, state: state)
    }
  }

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
