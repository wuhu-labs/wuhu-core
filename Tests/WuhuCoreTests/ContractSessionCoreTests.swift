import Foundation
import Testing
import WuhuAI
import WuhuAPI
@testable import WuhuCore

struct ContractSessionCoreTests {
  private func makeStore() throws -> SQLiteSessionStore {
    try SQLiteSessionStore(path: ":memory:")
  }

  private func makeSession(store: SQLiteSessionStore, systemPrompt: String = "You are helpful.") async throws -> WuhuSession {
    try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "mock",
      reasoningEffort: nil,
      systemPrompt: systemPrompt,
      cwd: "/tmp",
      parentSessionID: nil,
    )
  }

  private func makeBehavior(
    sessionID: String,
    store: SQLiteSessionStore,
    streamFn: @escaping StreamFn = { model, _, _ in
      AsyncThrowingStream { continuation in
        continuation.yield(.done(message: .init(provider: model.provider, model: model.id, content: [.text("ok")], stopReason: .stop)))
        continuation.finish()
      }
    },
    tools: [AnyAgentTool] = [],
  ) async -> (behavior: WuhuSessionBehavior, config: WuhuSessionRuntimeConfig) {
    let config = WuhuSessionRuntimeConfig()
    await config.setToolProvider { _ in tools }
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let behavior = WuhuSessionBehavior(sessionID: .init(rawValue: sessionID), store: store, runtimeConfig: config, blobStore: blobStore, streamFn: streamFn)
    return (behavior, config)
  }

  private func makeStateAwareBehavior(
    sessionID: String,
    store: SQLiteSessionStore,
    streamFn: @escaping StreamFn,
  ) async -> (behavior: WuhuSessionBehavior, config: WuhuSessionRuntimeConfig, service: WuhuService) {
    let config = WuhuSessionRuntimeConfig()
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore)

    await config.setToolProvider { [service] state in
      return await service.agentToolset(
        currentSessionID: state.session.id,
        hasPrimaryMount: state.mounts.primaryMount != nil,
      )
    }

    let behavior = WuhuSessionBehavior(
      sessionID: .init(rawValue: sessionID),
      store: store,
      runtimeConfig: config,
      blobStore: blobStore,
      streamFn: streamFn,
    )
    return (behavior, config, service)
  }

  private func applyAndAssertInvariant(
    _ behavior: WuhuSessionBehavior,
    _ state: WuhuSessionLoopState,
    _ fn: (inout WuhuSessionLoopState) async throws -> Void,
  ) async throws -> WuhuSessionLoopState {
    var next = state
    try await fn(&next)
    let durable = if let diff = behavior.diff(from: state, to: next) {
      try await behavior.persist(diff, from: state, to: next)
    } else {
      next
    }
    let reloaded = try await behavior.loadState()
    #expect(durable == reloaded)
    return reloaded
  }

  private func runBehaviorTurn(
    _ behavior: WuhuSessionBehavior,
    startingFrom initialState: WuhuSessionLoopState,
  ) async throws -> (state: WuhuSessionLoopState, assistant: AssistantMessage) {
    let context = behavior.buildContext(state: initialState)
    let assistant = try await behavior.infer(
      context: context,
      stream: .init(yield: { _ in }),
    )

    var state = try await applyAndAssertInvariant(behavior, initialState) { state in
      behavior.persistAssistantEntry(assistant, state: &state)
    }

    let calls = assistant.content.compactMap { block -> ToolCall? in
      if case let .toolCall(call) = block { return call }
      return nil
    }

    for call in calls {
      state = try await applyAndAssertInvariant(behavior, state) { state in
        behavior.toolWillExecute(call, state: &state)
      }

      let result = try await behavior.executeToolCall(call, state: state)

      state = try await applyAndAssertInvariant(behavior, state) { state in
        behavior.toolDidExecute(call, result: result, state: &state)
      }
    }

    return (state, assistant)
  }

  @Test func ioInvariant_handleEnqueueAndDrainAndPersistAssistant() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)
    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store)

    var state = try await behavior.loadState()

    // Enqueue follow-up
    let qid = QueueItemID(rawValue: "q1")
    let message = QueuedUserMessage(author: Author.unknown, content: MessageContent.text("hello"))
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try behavior.handle(WuhuSessionExternalAction.enqueueUser(id: qid, message: message, lane: .followUp), state: &state)
    }

    // Materialize follow-up at turn boundary
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainTurnItems(state: &state)
    }
    #expect(state.entries.contains { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .user(u) = m else { return false }
      return u.content.contains { if case let .text(text, _) = $0 { return text == "hello" }; return false }
    })

    // Persist assistant response (no tool calls) should bring status back to idle.
    let assistant = AssistantMessage(provider: .openai, model: "mock", content: [.text("ok")], stopReason: .stop)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.persistAssistantEntry(assistant, state: &state)
    }
    #expect(state.status.status == .idle)
  }

  @Test func ioInvariant_toolLifecycleAndCrashRecovery() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)

    let tool = AnyAgentTool(
      tool: .init(name: "echo", description: "Echoes input", parameters: .object([:])),
      label: "Echo",
      execute: { _, _ in .init(content: [.text("echoed")]) },
    )

    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store, tools: [tool])
    var state = try await behavior.loadState()

    // Enqueue + drain user message.
    let qid = QueueItemID(rawValue: "q2")
    state = try await applyAndAssertInvariant(behavior, state) { state in
      let message = QueuedUserMessage(author: Author.unknown, content: MessageContent.text("run tool"))
      try behavior.handle(WuhuSessionExternalAction.enqueueUser(id: qid, message: message, lane: .followUp), state: &state)
    }
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainTurnItems(state: &state)
    }

    // Persist assistant with tool call.
    let call = ToolCall(id: "t1", name: "echo", arguments: .object([:]))
    let assistantWithTool = AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(call)], stopReason: .toolUse)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.persistAssistantEntry(assistantWithTool, state: &state)
    }
    #expect(state.toolCallStatus["t1"] == ToolCallStatus.pending)

    // Mark started.
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.toolWillExecute(call, state: &state)
    }
    #expect(state.toolCallStatus["t1"] == ToolCallStatus.started)

    // Simulate crash: recover stale tool call should append an errored tool result.
    let stale = behavior.staleToolCallIDs(in: state)
    #expect(stale == ["t1"])

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.recoverStaleToolCall(id: "t1", state: &state)
    }
    #expect(state.toolCallStatus["t1"] == ToolCallStatus.errored)
    #expect(state.entries.contains { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .toolResult(t) = m else { return false }
      return t.toolCallId == "t1" && t.isError == true
    })
  }

  @Test func ioInvariant_drainInterruptOrdersSystemBeforeSteerByTimestamp() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)
    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store)
    var state = try await behavior.loadState()

    // System input at an earlier timestamp.
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.handle(
        .enqueueSystem(
          id: .init(rawValue: "sys1"),
          input: .init(source: .asyncTaskNotification, content: .text("{\"type\":\"system\"}")),
          enqueuedAt: Date(timeIntervalSince1970: 0),
        ),
        state: &state,
      )
    }

    // Steer input enqueued later via behavior handle.
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try behavior.handle(WuhuSessionExternalAction.enqueueUser(
        id: .init(rawValue: "steer1"),
        message: QueuedUserMessage(author: Author.unknown, content: MessageContent.text("{\"type\":\"steer\"}")),
        lane: .steer,
      ), state: &state)
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainInterruptItems(state: &state)
    }

    let appended = state.entries.filter { $0.parentEntryID != nil }
    #expect(appended.count >= 2)
    if appended.count >= 2 {
      #expect(appended[0].createdAt <= appended[1].createdAt)
    }
  }

  @Test func ioInvariant_compactionAppendsEntry() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)

    // Very small context window to force cut points.
    setenv("WUHU_COMPACTION_ENABLED", "1", 1)
    setenv("WUHU_COMPACTION_KEEP_RECENT_TOKENS", "10", 1)

    defer {
      unsetenv("WUHU_COMPACTION_ENABLED")
      unsetenv("WUHU_COMPACTION_KEEP_RECENT_TOKENS")
    }

    let summarizer: StreamFn = { model, _, _ in
      AsyncThrowingStream { continuation in
        let assistant = AssistantMessage(
          provider: model.provider,
          model: model.id,
          content: [.text("summary")],
          stopReason: .stop,
        )
        continuation.yield(.done(message: assistant))
        continuation.finish()
      }
    }

    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store, streamFn: summarizer)
    var state = try await behavior.loadState()

    // Add some transcript messages.
    for i in 0 ..< 12 {
      _ = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.user("u\(i)"))))
      _ = try await store.appendEntry(sessionID: session.id, payload: .message(.fromPi(.assistant(AssistantMessage(provider: .openai, model: "mock", content: [.text("a\(i)")], stopReason: .stop)))))
    }

    state = try await behavior.loadState()

    state = try await applyAndAssertInvariant(behavior, state) { state in
      state = try await behavior.performCompaction(state: state)
    }

    #expect(state.entries.contains { entry in
      if case .compaction = entry.payload { return true }
      return false
    })
  }

  @Test func behaviorTurn_mountThenListUsesMountedPath() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "wuhu-behavior-turn-\(UUID().uuidString.lowercased())",
      isDirectory: true,
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    try "hello".write(
      to: root.appendingPathComponent("hello.txt"),
      atomically: true,
      encoding: .utf8,
    )

    let store = try makeStore()
    let session = try await makeSession(store: store, systemPrompt: "You are helpful.")

    let mock = MockStreamFn(responses: [
      .toolCalls([
        .init(
          id: "tc-mount",
          name: WuhuAgentToolNames.mount,
          arguments: .object([
            "path": .string(root.path),
            "name": .string("workspace"),
          ]),
        ),
        .init(
          id: "tc-ls",
          name: "ls",
          arguments: .object([
            "path": .string("."),
          ]),
        ),
      ]),
    ])

    let (behavior, _, _) = await makeStateAwareBehavior(
      sessionID: session.id,
      store: store,
      streamFn: mock.streamFn,
    )

    var state = try await behavior.loadState()

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.handle(
        .enqueueUser(
          id: .init(rawValue: "q-mount-list"),
          message: .init(author: .unknown, content: .text("Mount /tmp and list what we have")),
          lane: .followUp,
        ),
        state: &state,
      )
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainTurnItems(state: &state)
    }

    let result = try await runBehaviorTurn(behavior, startingFrom: state)
    state = result.state

    let calls = result.assistant.content.compactMap { block -> ToolCall? in
      if case let .toolCall(call) = block { return call }
      return nil
    }
    #expect(calls.map(\.name) == [WuhuAgentToolNames.mount, "ls"])

    #expect(state.mounts.primaryMount?.path == root.path)
    #expect(state.session.cwd == root.path)

    let toolResults = state.entries.compactMap { entry -> WuhuToolResultMessage? in
      guard case let .message(.toolResult(result)) = entry.payload else { return nil }
      return result
    }
    let lsResult = try #require(toolResults.last { $0.toolCallId == "tc-ls" })
    let lsText = lsResult.content.compactMap { block -> String? in
      if case let .text(text, _) = block { return text }
      return nil
    }.joined(separator: "\n")
    #expect(lsText.contains("hello.txt"))
  }

  // MARK: - Rich content materialization

  @Test func drainTurnBoundary_materializesRichContentWithImages() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)
    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store)

    var state = try await behavior.loadState()

    // Enqueue a follow-up message with rich content (text + image)
    let richContent = MessageContent.richContent([
      .text("Who is this?"),
      .image(blobURI: "blob://\(session.id)/photo.jpg", mimeType: "image/jpeg"),
    ])
    let message = QueuedUserMessage(author: Author.unknown, content: richContent)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-rich-1"), message: message, lane: .followUp),
        state: &state,
      )
    }

    // Materialize at turn boundary
    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainTurnItems(state: &state)
    }

    // Verify the materialized entry preserves both text and image
    let userEntry = state.entries.first { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case .user = m else { return false }
      return true
    }
    let userMsg = try #require(userEntry.flatMap { entry -> WuhuUserMessage? in
      guard case let .message(.user(u)) = entry.payload else { return nil }
      return u
    })
    #expect(userMsg.content.count == 2)
    #expect(userMsg.content[0] == .text(text: "Who is this?", signature: nil))
    #expect(userMsg.content[1] == .image(blobURI: "blob://\(session.id)/photo.jpg", mimeType: "image/jpeg"))
  }

  @Test func drainTurnBoundary_materializesImageOnlyMessage() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)
    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store)

    var state = try await behavior.loadState()

    // Enqueue a follow-up with image only (no text), like the original bug report
    let richContent = MessageContent.richContent([
      .image(blobURI: "blob://\(session.id)/photo.png", mimeType: "image/png"),
    ])
    let message = QueuedUserMessage(author: Author.unknown, content: richContent)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-img-only"), message: message, lane: .followUp),
        state: &state,
      )
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainTurnItems(state: &state)
    }

    let userMsg = try #require(state.entries.compactMap { entry -> WuhuUserMessage? in
      guard case let .message(.user(u)) = entry.payload else { return nil }
      return u
    }.last)
    #expect(userMsg.content.count == 1)
    #expect(userMsg.content[0] == .image(blobURI: "blob://\(session.id)/photo.png", mimeType: "image/png"))
  }

  @Test func drainInterruptCheckpoint_materializesRichContentSteerMessage() async throws {
    let store = try makeStore()
    let session = try await makeSession(store: store)
    let (behavior, _) = await makeBehavior(sessionID: session.id, store: store)

    var state = try await behavior.loadState()

    // Enqueue a steer message with rich content
    let richContent = MessageContent.richContent([
      .text("Look at this"),
      .image(blobURI: "blob://\(session.id)/steer.jpg", mimeType: "image/jpeg"),
    ])
    let message = QueuedUserMessage(author: Author.unknown, content: richContent)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-steer-rich"), message: message, lane: .steer),
        state: &state,
      )
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      behavior.drainInterruptItems(state: &state)
    }

    let userMsg = try #require(state.entries.compactMap { entry -> WuhuUserMessage? in
      guard case let .message(.user(u)) = entry.payload else { return nil }
      return u
    }.last)
    #expect(userMsg.content.count == 2)
    #expect(userMsg.content[0] == .text(text: "Look at this", signature: nil))
    #expect(userMsg.content[1] == .image(blobURI: "blob://\(session.id)/steer.jpg", mimeType: "image/jpeg"))
  }
}
