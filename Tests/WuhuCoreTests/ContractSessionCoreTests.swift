import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore

struct ContractSessionCoreTests {
  private func makeStore() throws -> SQLiteSessionStore {
    try SQLiteSessionStore(path: ":memory:")
  }

  private func makeSession(store: SQLiteSessionStore, systemPrompt: String = "You are helpful.") async throws -> WuhuSession {
    try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      sessionType: .coding,
      provider: .openai,
      model: "mock",
      reasoningEffort: nil,
      systemPrompt: systemPrompt,
      environmentID: nil,
      environment: .init(name: "test", type: .local, path: "/tmp"),
      runnerName: nil,
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
    await config.setStreamFn(streamFn)
    await config.setTools(tools)
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    return (WuhuSessionBehavior(sessionID: .init(rawValue: sessionID), store: store, runtimeConfig: config, blobStore: blobStore), config)
  }

  private func applyAndAssertInvariant(
    _ behavior: WuhuSessionBehavior,
    _ state: WuhuSessionLoopState,
    _ fn: @Sendable (WuhuSessionLoopState) async throws -> [WuhuSessionCommittedAction],
  ) async throws -> WuhuSessionLoopState {
    var next = state
    let actions = try await fn(state)
    for action in actions {
      behavior.apply(action, to: &next)
    }
    let reloaded = try await behavior.loadState()
    if next != reloaded {
      #expect(next.entries.map(\.id) == reloaded.entries.map(\.id))
      if next.entries.count == reloaded.entries.count {
        for (a, b) in zip(next.entries, reloaded.entries) where a != b {
          #expect(a.id == b.id)
          #expect(a.parentEntryID == b.parentEntryID)
          #expect(a.createdAt == b.createdAt)
          #expect(a.payload == b.payload)
          break
        }
      }
      #expect(next.toolCallStatus == reloaded.toolCallStatus)
      #expect(next.settings == reloaded.settings)
      #expect(next.status == reloaded.status)
      #expect(next.systemUrgent == reloaded.systemUrgent)
      #expect(next.steer == reloaded.steer)
      #expect(next.followUp == reloaded.followUp)
    }
    #expect(next == reloaded)
    return next
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
      try await behavior.handle(WuhuSessionExternalAction.enqueueUser(id: qid, message: message, lane: .followUp), state: state)
    }

    // Materialize follow-up at turn boundary
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainTurnItems(state: state)
    }
    #expect(state.entries.contains { entry in
      guard case let .message(m) = entry.payload else { return false }
      guard case let .user(u) = m else { return false }
      return u.content.contains { if case let .text(text, _) = $0 { return text == "hello" }; return false }
    })

    // Persist assistant response (no tool calls) should bring status back to idle.
    let assistant = AssistantMessage(provider: .openai, model: "mock", content: [.text("ok")], stopReason: .stop)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.persistAssistantEntry(assistant, state: state)
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
      return try await behavior.handle(WuhuSessionExternalAction.enqueueUser(id: qid, message: message, lane: .followUp), state: state)
    }
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainTurnItems(state: state)
    }

    // Persist assistant with tool call.
    let call = ToolCall(id: "t1", name: "echo", arguments: .object([:]))
    let assistantWithTool = AssistantMessage(provider: .openai, model: "mock", content: [.toolCall(call)], stopReason: .toolUse)
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.persistAssistantEntry(assistantWithTool, state: state)
    }
    #expect(state.toolCallStatus["t1"] == ToolCallStatus.pending)

    // Mark started.
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.toolWillExecute(call, state: state)
    }
    #expect(state.toolCallStatus["t1"] == ToolCallStatus.started)

    // Simulate crash: recover stale tool call should append an errored tool result.
    let stale = behavior.staleToolCallIDs(in: state)
    #expect(stale == ["t1"])

    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.recoverStaleToolCall(id: "t1", state: state)
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
    _ = try await store.enqueueSystemInput(
      sessionID: .init(rawValue: session.id),
      id: .init(rawValue: "sys1"),
      input: .init(source: .asyncTaskNotification, content: .text("{\"type\":\"system\"}")),
      enqueuedAt: Date(timeIntervalSince1970: 0),
    )
    state = try await behavior.loadState()

    // Steer input enqueued later via behavior handle.
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.handle(WuhuSessionExternalAction.enqueueUser(
        id: .init(rawValue: "steer1"),
        message: QueuedUserMessage(author: Author.unknown, content: MessageContent.text("{\"type\":\"steer\"}")),
        lane: .steer,
      ), state: state)
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainInterruptItems(state: state)
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
      try await behavior.performCompaction(state: state)
    }

    #expect(state.entries.contains { entry in
      if case .compaction = entry.payload { return true }
      return false
    })
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
      try await behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-rich-1"), message: message, lane: .followUp),
        state: state,
      )
    }

    // Materialize at turn boundary
    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainTurnItems(state: state)
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
      try await behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-img-only"), message: message, lane: .followUp),
        state: state,
      )
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainTurnItems(state: state)
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
      try await behavior.handle(
        WuhuSessionExternalAction.enqueueUser(id: .init(rawValue: "q-steer-rich"), message: message, lane: .steer),
        state: state,
      )
    }

    state = try await applyAndAssertInvariant(behavior, state) { state in
      try await behavior.drainInterruptItems(state: state)
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
