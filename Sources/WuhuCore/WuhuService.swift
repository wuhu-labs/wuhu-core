import Foundation
import PiAI
import WuhuAPI

public actor WuhuService {
  let store: SQLiteSessionStore
  let blobStore: WuhuBlobStore
  private let retryPolicy: WuhuLLMRetryPolicy
  private let asyncBashRegistry: WuhuAsyncBashRegistry
  let workspaceRoot: String?
  private let braveSearchAPIKey: String?
  private let instanceID: String
  private let eventHub = WuhuLiveEventHub()
  private let subscriptionHub = WuhuSessionSubscriptionHub()
  private var asyncBashRouter: WuhuAsyncBashCompletionRouter?
  public let runnerRegistry: RunnerRegistry
  private let streamFnOverride: StreamFn?

  private var runtimes: [String: WuhuSessionRuntime] = [:]

  public init(
    store: SQLiteSessionStore,
    blobStore: WuhuBlobStore,
    retryPolicy: WuhuLLMRetryPolicy = .init(),
    asyncBashRegistry: WuhuAsyncBashRegistry = .shared,
    workspaceRoot: String? = nil,
    braveSearchAPIKey: String? = nil,
    runnerRegistry: RunnerRegistry? = nil,
    streamFn: StreamFn? = nil,
  ) {
    self.store = store
    self.blobStore = blobStore
    self.retryPolicy = retryPolicy
    self.asyncBashRegistry = asyncBashRegistry
    self.workspaceRoot = workspaceRoot
    self.braveSearchAPIKey = braveSearchAPIKey
    self.runnerRegistry = runnerRegistry ?? RunnerRegistry()
    streamFnOverride = streamFn
    instanceID = UUID().uuidString.lowercased()
  }

  deinit {
    let router = asyncBashRouter
    let registry = asyncBashRegistry
    if let router {
      Task { await router.stop() }
    }
    Task { await registry.stopReapWatchdog() }
  }

  public func startAgentLoopManager() async {
    await ensureAsyncBashRouter()
  }

  private func ensureAsyncBashRouter() async {
    guard asyncBashRouter == nil else { return }
    let router = WuhuAsyncBashCompletionRouter(
      registry: asyncBashRegistry,
      instanceID: instanceID,
      enqueueSystemJSON: { [weak self] sessionID, jsonText, timestamp in
        guard let self else { return }
        do {
          try await enqueueSystemJSON(sessionID: sessionID, jsonText: jsonText, timestamp: timestamp)
        } catch {
          let line = "[WuhuService] ERROR: failed to enqueue async bash completion for session '\(sessionID)': \(String(describing: error))\n"
          FileHandle.standardError.write(Data(line.utf8))
        }
      },
    )
    asyncBashRouter = router
    await router.start()
    await asyncBashRegistry.startReapWatchdog()
  }

  private func runtime(for sessionID: String) -> WuhuSessionRuntime {
    if let existing = runtimes[sessionID] { return existing }
    let runtime = WuhuSessionRuntime(
      sessionID: .init(rawValue: sessionID),
      store: store,
      eventHub: eventHub,
      subscriptionHub: subscriptionHub,
      blobStore: blobStore,
      onIdle: nil,
    )
    runtimes[sessionID] = runtime
    return runtime
  }

  private func enqueueSystemJSON(sessionID: String, jsonText: String, timestamp: Date) async throws {
    let input = SystemUrgentInput(source: .asyncBashCallback, content: .text(jsonText))
    try await runtime(for: sessionID).enqueueSystem(input: input, enqueuedAt: timestamp)
  }

  private func logServiceError(_ message: String, error: Error) {
    let line = "[WuhuService] ERROR: \(message): \(String(describing: error))\n"
    FileHandle.standardError.write(Data(line.utf8))
  }

  func loadFinalAssistantMessage(sessionID: String) async throws -> (entryID: Int64, text: String) {
    var beforeEntryID: Int64?
    while true {
      let entries = try await store.getEntriesReverse(sessionID: sessionID, beforeEntryID: beforeEntryID, limit: 256)
      guard !entries.isEmpty else { break }

      for entry in entries {
        guard case let .message(m) = entry.payload else { continue }
        guard case let .assistant(a) = m else { continue }

        let hasToolCalls = a.content.contains { block in
          if case .toolCall = block { return true }
          return false
        }
        if hasToolCalls { continue }

        let text = a.content.compactMap { block -> String? in
          if case let .text(text: text, signature: _) = block { return text }
          return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return (entryID: entry.id, text: text.isEmpty ? "(no text)" : text)
      }

      beforeEntryID = entries.last?.id
    }

    throw PiAIError.unsupported("No final assistant message found for session '\(sessionID)'")
  }

  public func renameSession(sessionID: String, title: String) async throws -> WuhuSession {
    try await store.renameSession(id: sessionID, title: title)
  }

  public func archiveSession(sessionID: String) async throws -> WuhuSession {
    try await store.archiveSession(id: sessionID)
  }

  public func unarchiveSession(sessionID: String) async throws -> WuhuSession {
    try await store.unarchiveSession(id: sessionID)
  }

  public func setSessionModel(sessionID: String, request: WuhuSetSessionModelRequest) async throws -> WuhuSetSessionModelResponse {
    _ = try await store.getSession(id: sessionID)

    let effectiveModel: String = {
      let trimmed = (request.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
      return WuhuModelCatalog.defaultModelID(for: request.provider)
    }()

    let selection = WuhuSessionSettings(
      provider: request.provider,
      model: effectiveModel,
      reasoningEffort: request.reasoningEffort,
    )

    let applied = try await runtime(for: sessionID).setModelSelection(selection)
    let session = try await store.getSession(id: sessionID)
    return .init(session: session, selection: selection, applied: applied)
  }

  public func createSession(
    sessionID: String,
    provider: WuhuProvider,
    model: String,
    reasoningEffort: ReasoningEffort? = nil,
    systemPrompt: String,
    cwd: String?,
    parentSessionID: String? = nil,
  ) async throws -> WuhuSession {
    let session = try await store.createSession(
      sessionID: sessionID,
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
      systemPrompt: systemPrompt,
      cwd: cwd,
      parentSessionID: parentSessionID,
    )

    // Emit workspace-level context entries if workspace root is configured
    if let workspaceRoot {
      try await emitWorkspaceContext(sessionID: session.id, workspaceRoot: workspaceRoot)
    }

    return try await store.getSession(id: session.id)
  }

  /// Emit context entries for a mount (AGENTS.md, skills).
  public func emitMountContext(sessionID: String, mount: WuhuMount) async throws {
    try await emitMountContext(sessionID: sessionID, mount: mount, runner: nil)
  }

  /// Emit mount-level context entries (announcement, AGENTS.md, skills).
  ///
  /// When `runner` is provided, files are read via the runner's FileIO ops (works for both local and remote).
  /// When `runner` is nil, files are read from the local filesystem.
  public func emitMountContext(sessionID: String, mount: WuhuMount, runner: (any Runner)?) async throws {
    // Mount announcement
    let announcementPayload: WuhuEntryPayload = .custom(
      customType: WuhuCustomMessageTypes.mountContext,
      data: .object([
        "mountID": .string(mount.id),
        "name": .string(mount.name),
        "path": .string(mount.path),
        "text": .string("Mounted '\(mount.name)' at \(mount.path)"),
      ]),
    )
    _ = try await store.appendEntry(sessionID: sessionID, payload: announcementPayload)

    // Mount-level AGENTS.md
    let agentsFiles: [WuhuContextFile] = if let runner {
      await loadAgentsFilesViaRunner(runner: runner, root: mount.path)
    } else {
      loadAgentsFiles(at: mount.path)
    }
    if !agentsFiles.isEmpty {
      let rendered = WuhuContextRenderer.renderAgentsFiles(agentsFiles)
      let agentsPayload: WuhuEntryPayload = .custom(
        customType: WuhuCustomMessageTypes.agentsContext,
        data: .object([
          "source": .string("mount"),
          "mountID": .string(mount.id),
          "text": .string(rendered),
        ]),
      )
      _ = try await store.appendEntry(sessionID: sessionID, payload: agentsPayload)
    }

    // Mount-level skills
    let mountSkills: [WuhuSkill]
    if let runner {
      mountSkills = await loadSkillsViaRunner(runner: runner, root: mount.path)
    } else {
      let mountSkillsDir = URL(fileURLWithPath: mount.path, isDirectory: true)
        .appendingPathComponent(".wuhu")
        .appendingPathComponent("skills")
        .path
      mountSkills = WuhuSkillsLoader.load(userSkillsDir: "/dev/null", projectSkillsDir: mountSkillsDir)
    }
    if !mountSkills.isEmpty {
      let rendered = WuhuSkills.promptSection(skills: mountSkills)
      let skillsPayload: WuhuEntryPayload = .custom(
        customType: WuhuCustomMessageTypes.skillsContext,
        data: .object([
          "source": .string("mount"),
          "mountID": .string(mount.id),
          "text": .string(rendered),
        ]),
      )
      _ = try await store.appendEntry(sessionID: sessionID, payload: skillsPayload)
    }
  }

  /// Emit workspace-level context entries (AGENTS.md, skills).
  private func emitWorkspaceContext(sessionID: String, workspaceRoot: String) async throws {
    // Workspace AGENTS.md
    let agentsFiles = loadAgentsFiles(at: workspaceRoot)
    if !agentsFiles.isEmpty {
      let rendered = WuhuContextRenderer.renderAgentsFiles(agentsFiles)
      let agentsPayload: WuhuEntryPayload = .custom(
        customType: WuhuCustomMessageTypes.agentsContext,
        data: .object([
          "source": .string("workspace"),
          "text": .string(rendered),
        ]),
      )
      _ = try await store.appendEntry(sessionID: sessionID, payload: agentsPayload)
    }

    // Workspace skills (from workspace root + ~/.wuhu/skills/)
    let homeSkillsDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu")
      .appendingPathComponent("skills")
      .path
    let workspaceSkillsDir = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
      .appendingPathComponent("skills")
      .path
    let skills = WuhuSkillsLoader.load(
      userSkillsDir: homeSkillsDir,
      workspaceSkillsDir: workspaceSkillsDir,
      projectSkillsDir: "/dev/null",
    )
    if !skills.isEmpty {
      let rendered = WuhuSkills.promptSection(skills: skills)
      let skillsPayload: WuhuEntryPayload = .custom(
        customType: WuhuCustomMessageTypes.skillsContext,
        data: .object([
          "source": .string("workspace"),
          "text": .string(rendered),
        ]),
      )
      _ = try await store.appendEntry(sessionID: sessionID, payload: skillsPayload)
    }
  }

  public func listSessions(limit: Int? = nil, includeArchived: Bool = false) async throws -> [WuhuSession] {
    try await store.listSessions(limit: limit, includeArchived: includeArchived)
  }

  public func getSession(id: String) async throws -> WuhuSession {
    try await store.getSession(id: id)
  }

  public func getTranscript(sessionID: String) async throws -> [WuhuSessionEntry] {
    try await store.getEntries(sessionID: sessionID)
  }

  public func getTranscript(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
  ) async throws -> [WuhuSessionEntry] {
    try await store.getEntries(sessionID: sessionID, sinceCursor: sinceCursor, sinceTime: sinceTime)
  }

  public func inProcessExecutionInfo(sessionID: String) async -> WuhuInProcessExecutionInfo {
    if let runtime = runtimes[sessionID] {
      return await runtime.inProcessExecutionInfo()
    }
    return .init(activePromptCount: 0)
  }

  public func stopSession(sessionID: String, user: String? = nil) async throws -> WuhuStopSessionResponse {
    let hadRuntime = runtimes[sessionID] != nil
    if let runtime = runtimes[sessionID] {
      await runtime.stop()
      runtimes[sessionID] = nil
    }

    _ = try await store.getSession(id: sessionID)

    var transcript = try await store.getEntries(sessionID: sessionID)
    let inferred = WuhuSessionExecutionInference.infer(from: transcript)

    let shouldAppendStopMarker = hadRuntime || inferred.state == .executing
    guard shouldAppendStopMarker else {
      return .init(repairedEntries: [], stopEntry: nil)
    }

    let toolRepair = try await WuhuToolRepairer.repairMissingToolResultsIfNeeded(
      sessionID: sessionID,
      transcript: transcript,
      mode: .stopped,
      store: store,
      eventHub: eventHub,
    )
    transcript = toolRepair.transcript

    for toolCallId in inferred.pendingToolCallIds.sorted() {
      _ = try await store.setToolCallStatus(sessionID: .init(rawValue: sessionID), id: toolCallId, status: .errored)
    }

    let stoppedBy = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var details: [String: JSONValue] = ["wuhu_event": .string("execution_stopped")]
    if !stoppedBy.isEmpty {
      details["user"] = .string(stoppedBy)
    }

    let stopMessage = WuhuPersistedMessage.customMessage(.init(
      customType: WuhuCustomMessageTypes.executionStopped,
      content: [.text(text: "Execution stopped", signature: nil)],
      details: .object(details),
      display: true,
      timestamp: Date(),
    ))
    let stopEntry = try await store.appendEntry(sessionID: sessionID, payload: .message(stopMessage))
    try await store.setSessionExecutionStatus(sessionID: .init(rawValue: sessionID), status: .stopped)

    await eventHub.publish(sessionID: sessionID, event: .entryAppended(stopEntry))
    await eventHub.publish(sessionID: sessionID, event: .idle)

    await subscriptionHub.publish(
      sessionID: sessionID,
      event: .transcriptAppended([stopEntry]),
    )
    if let status = try? await store.loadStatusSnapshot(sessionID: .init(rawValue: sessionID)) {
      await subscriptionHub.publish(sessionID: sessionID, event: .statusUpdated(status))
    }

    return .init(repairedEntries: toolRepair.repairEntries, stopEntry: stopEntry)
  }

  public func followSessionStream(
    sessionID: String,
    sinceCursor: Int64?,
    sinceTime: Date?,
    stopAfterIdle: Bool,
    timeoutSeconds: Double?,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let live = await eventHub.subscribe(sessionID: sessionID)
    let initial = try await store.getEntries(sessionID: sessionID, sinceCursor: sinceCursor, sinceTime: sinceTime)
    let lastInitialCursor = initial.last?.id ?? sinceCursor ?? 0
    let status = try? await store.loadStatusSnapshot(sessionID: .init(rawValue: sessionID))
    let initiallyIdle: Bool = if let runtime = runtimes[sessionID] {
      if status?.status == .running {
        false
      } else {
        await runtime.isIdle()
      }
    } else {
      true
    }

    return AsyncThrowingStream(WuhuSessionStreamEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let forwardTask = Task {
        do {
          for entry in initial {
            continuation.yield(.entryAppended(entry))
          }

          if stopAfterIdle, initiallyIdle {
            continuation.yield(.idle)
            continuation.yield(.done)
            continuation.finish()
            return
          }

          for await event in live {
            switch event {
            case let .entryAppended(entry):
              if entry.id <= lastInitialCursor { continue }
              continuation.yield(event)
            case .assistantTextDelta, .idle:
              continuation.yield(event)
              if stopAfterIdle, case .idle = event {
                continuation.yield(.done)
                continuation.finish()
                return
              }
            case .done:
              break
            }
          }

          continuation.finish()
        }
      }

      let timeoutTask: Task<Void, Never>? = timeoutSeconds.flatMap { seconds in
        Task {
          let ns = UInt64(max(0, seconds) * 1_000_000_000)
          try? await Task.sleep(nanoseconds: ns)
          continuation.yield(.done)
          continuation.finish()
        }
      }

      continuation.onTermination = { _ in
        forwardTask.cancel()
        timeoutTask?.cancel()
      }
    }
  }
}

// MARK: - Context helpers

private func loadAgentsFiles(at root: String) -> [WuhuContextFile] {
  let fm = FileManager.default
  let candidates = [
    URL(fileURLWithPath: root).appendingPathComponent("AGENTS.md").path,
    URL(fileURLWithPath: root).appendingPathComponent("AGENTS.local.md").path,
  ]

  var files: [WuhuContextFile] = []
  for path in candidates {
    guard fm.fileExists(atPath: path) else { continue }
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    files.append(.init(path: path, content: content))
  }
  return files
}

/// Load AGENTS.md files via a runner's FileIO ops (works for both local and remote runners).
private func loadAgentsFilesViaRunner(runner: any Runner, root: String) async -> [WuhuContextFile] {
  let candidates = [
    URL(fileURLWithPath: root).appendingPathComponent("AGENTS.md").path,
    URL(fileURLWithPath: root).appendingPathComponent("AGENTS.local.md").path,
  ]

  var files: [WuhuContextFile] = []
  for path in candidates {
    do {
      let existence = try await runner.exists(path: path)
      guard existence == .file else { continue }
      let content = try await runner.readString(path: path, encoding: .utf8)
      files.append(.init(path: path, content: content))
    } catch {
      // Skip files that fail to read (same behavior as local loadAgentsFiles)
      continue
    }
  }
  return files
}

/// Load skills from `.wuhu/skills/` via a runner's FileIO ops.
/// Uses `runner.find` to locate SKILL.md files, then reads each one.
private func loadSkillsViaRunner(runner: any Runner, root: String) async -> [WuhuSkill] {
  let skillsDir = URL(fileURLWithPath: root, isDirectory: true)
    .appendingPathComponent(".wuhu")
    .appendingPathComponent("skills")
    .path

  // Check if skills directory exists
  do {
    let existence = try await runner.exists(path: skillsDir)
    guard existence == .directory else { return [] }
  } catch {
    return []
  }

  // Find all SKILL.md files
  let findResult: FindResult
  do {
    findResult = try await runner.find(params: FindParams(root: skillsDir, pattern: "**/SKILL.md", limit: 200))
  } catch {
    return []
  }

  var byName: [String: WuhuSkill] = [:]
  for entry in findResult.entries {
    let absolutePath = URL(fileURLWithPath: skillsDir).appendingPathComponent(entry.relativePath).path
    do {
      let content = try await runner.readString(path: absolutePath, encoding: .utf8)
      if let skill = WuhuSkillsLoader.loadSkillFromContent(content, filePath: absolutePath, source: "project") {
        byName[skill.name] = skill
      }
    } catch {
      continue
    }
  }

  return byName.values.sorted { $0.name < $1.name }
}

struct WuhuContextFile: Sendable, Hashable {
  var path: String
  var content: String
}

enum WuhuContextRenderer {
  static func renderAgentsFiles(_ files: [WuhuContextFile]) -> String {
    guard !files.isEmpty else { return "" }
    var s = "# Project Context\n\n"
    s += "Project-specific instructions and guidelines:\n\n"
    for f in files {
      s += "## \(f.path)\n\n"
      s += f.content
      if !s.hasSuffix("\n") { s += "\n" }
      s += "\n"
    }
    return s
  }
}

// MARK: - New session contracts

extension WuhuService: SessionCommanding, SessionSubscribing {
  public func enqueue(sessionID: SessionID, message: QueuedUserMessage, lane: UserQueueLane) async throws -> QueueItemID {
    await ensureAsyncBashRouter()
    let session = try await store.getSession(id: sessionID.rawValue)

    let asyncBash = WuhuAsyncBashToolContext(registry: asyncBashRegistry, sessionID: sessionID.rawValue, ownerID: instanceID)
    let sid = sessionID.rawValue
    let mountResolver = MountResolverFactory.make(
      sessionID: sid,
      store: store,
      runnerRegistry: runnerRegistry,
    )
    let baseTools = WuhuTools.codingAgentTools(
      cwdProvider: { [store] in try await store.getSession(id: sid).cwd },
      mountResolver: mountResolver,
      asyncBash: asyncBash,
      braveSearchAPIKey: braveSearchAPIKey,
    )
    let resolvedTools = agentToolset(session: session, baseTools: baseTools)

    let runtime = runtime(for: sessionID.rawValue)
    await runtime.setTools(resolvedTools)
    if let streamFnOverride {
      await runtime.setStreamFn(streamFnOverride)
    }
    await runtime.ensureStarted()
    return try await runtime.enqueue(message: message, lane: lane)
  }

  public func cancel(sessionID: SessionID, id: QueueItemID, lane: UserQueueLane) async throws {
    _ = try await store.getSession(id: sessionID.rawValue)
    let runtime = runtime(for: sessionID.rawValue)
    await runtime.ensureStarted()
    try await runtime.cancel(id: id, lane: lane)
  }

  public func subscribe(sessionID: SessionID, since request: SessionSubscriptionRequest) async throws -> SessionSubscription {
    _ = try await store.getSession(id: sessionID.rawValue)

    let live = await subscriptionHub.subscribe(sessionID: sessionID.rawValue)

    let runtime = runtime(for: sessionID.rawValue)
    await runtime.ensureStarted()

    var initial = try await loadInitialState(sessionID: sessionID, request: request)

    let inflightText = await runtime.currentInflightText()
    initial.inflightStreamText = inflightText

    let lastTranscriptID0: Int64 = {
      let fromRequest = Int64(request.transcriptSince?.rawValue ?? "") ?? 0
      let fromInitial = initial.transcript.last?.id ?? 0
      return max(fromRequest, fromInitial)
    }()

    let lastSystemCursor0 = Int64(initial.systemUrgent.cursor.rawValue) ?? 0
    let lastSteerCursor0 = Int64(initial.steer.cursor.rawValue) ?? 0
    let lastFollowUpCursor0 = Int64(initial.followUp.cursor.rawValue) ?? 0

    let events = AsyncThrowingStream(SessionEvent.self, bufferingPolicy: .bufferingNewest(4096)) { continuation in
      let forwardTask = Task {
        var lastTranscriptID = lastTranscriptID0
        var lastSystemCursor = lastSystemCursor0
        var lastSteerCursor = lastSteerCursor0
        var lastFollowUpCursor = lastFollowUpCursor0

        for await event in live {
          if Task.isCancelled { break }

          switch event {
          case let .transcriptAppended(entries):
            let filtered = entries.filter { $0.id > lastTranscriptID }
            guard !filtered.isEmpty else { continue }
            lastTranscriptID = max(lastTranscriptID, filtered.map(\.id).max() ?? lastTranscriptID)
            continuation.yield(.transcriptAppended(filtered))

          case let .systemUrgentQueue(cursor, entries):
            let cursorVal = Int64(cursor.rawValue) ?? 0
            if cursorVal <= lastSystemCursor { continue }
            lastSystemCursor = cursorVal
            continuation.yield(.systemUrgentQueue(cursor: cursor, entries: entries))

          case let .userQueue(cursor, entries):
            guard let lane = entries.first?.lane else {
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
              continue
            }
            let cursorVal = Int64(cursor.rawValue) ?? 0
            switch lane {
            case .steer:
              if cursorVal <= lastSteerCursor { continue }
              lastSteerCursor = cursorVal
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
            case .followUp:
              if cursorVal <= lastFollowUpCursor { continue }
              lastFollowUpCursor = cursorVal
              continuation.yield(.userQueue(cursor: cursor, entries: entries))
            }

          case let .settingsUpdated(settings):
            continuation.yield(.settingsUpdated(settings))

          case let .statusUpdated(status):
            continuation.yield(.statusUpdated(status))

          case .streamBegan, .streamDelta, .streamEnded:
            continuation.yield(event)
          }
        }
        continuation.finish()
      }

      continuation.onTermination = { _ in
        forwardTask.cancel()
      }
    }

    return .init(initial: initial, events: events)
  }

  private func loadInitialState(sessionID: SessionID, request: SessionSubscriptionRequest) async throws -> SessionInitialState {
    let settings = try await store.loadSettingsSnapshot(sessionID: sessionID)
    let status = try await store.loadStatusSnapshot(sessionID: sessionID)

    let sinceCursor = Int64(request.transcriptSince?.rawValue ?? "")
    let entries = try await store.getEntries(sessionID: sessionID.rawValue, sinceCursor: sinceCursor, sinceTime: nil)
    let transcript = entries

    let systemUrgent = try await store.loadSystemQueueBackfill(sessionID: sessionID, since: request.systemSince)
    let steer = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: .steer, since: request.steerSince)
    let followUp = try await store.loadUserQueueBackfill(sessionID: sessionID, lane: .followUp, since: request.followUpSince)

    return .init(
      settings: settings,
      status: status,
      transcript: transcript,
      systemUrgent: systemUrgent,
      steer: steer,
      followUp: followUp,
    )
  }
}
