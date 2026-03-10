import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore

struct JoinSessionsToolTests {
  // MARK: - Helpers

  private func newSessionID() -> String {
    UUID().uuidString.lowercased()
  }

  private func makeStoreAndService() throws -> (SQLiteSessionStore, WuhuService) {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))
    return (store, service)
  }

  private func createParentSession(
    store _: SQLiteSessionStore,
    service: WuhuService,
    sessionID: String? = nil,
  ) async throws -> WuhuSession {
    try await service.createSession(
      sessionID: sessionID ?? newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: "/tmp",
    )
  }

  private func createChildSession(
    store _: SQLiteSessionStore,
    service: WuhuService,
    parentSessionID: String,
    sessionID: String? = nil,
  ) async throws -> WuhuSession {
    try await service.createSession(
      sessionID: sessionID ?? newSessionID(),
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: "/tmp",
      parentSessionID: parentSessionID,
    )
  }

  /// Append a final assistant message (no tool calls) to a session.
  private func appendFinalAssistantMessage(
    store: SQLiteSessionStore,
    sessionID: String,
    text: String,
  ) async throws -> WuhuSessionEntry {
    try await store.appendEntry(sessionID: sessionID, payload: .message(.assistant(.init(
      provider: .openai,
      model: "mock",
      content: [.text(text: text, signature: nil)],
      usage: nil,
      stopReason: "stop",
      errorMessage: nil,
      timestamp: Date(),
    ))))
  }

  private func textOutput(_ result: ToolExecutionResult) throws -> String {
    try result.unwrapImmediate().content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  /// Build the join_sessions tool for a given parent session, using the real WuhuService.
  private func getJoinSessionsTool(service: WuhuService, parentSession: WuhuSession) async -> AnyAgentTool? {
    let baseTools = WuhuTools.codingAgentTools(cwdProvider: { "/tmp" }, mountResolver: WuhuTools.testMountResolver(cwd: "/tmp"))
    let allTools = await service.agentToolset(session: parentSession, baseTools: baseTools)
    return allTools.first { $0.tool.name == "join_sessions" }
  }

  // MARK: - Tests

  @Test func joinSessions_returnsImmediatelyWhenAllChildrenAlreadyIdle() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let child1 = try await createChildSession(store: store, service: service, parentSessionID: parent.id)
    let child2 = try await createChildSession(store: store, service: service, parentSessionID: parent.id)

    // Both children are idle by default (just created). Add final messages.
    _ = try await appendFinalAssistantMessage(store: store, sessionID: child1.id, text: "Child 1 done")
    _ = try await appendFinalAssistantMessage(store: store, sessionID: child2.id, text: "Child 2 done")

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    let result = try await tool.execute(
      toolCallId: "tc1",
      args: .object(["sessionIDs": .array([.string(child1.id), .string(child2.id)])]),
    )

    let text = try textOutput(result)
    #expect(text.contains("All 2 sessions completed."))
    #expect(text.contains("Child 1 done"))
    #expect(text.contains("Child 2 done"))

    // Check details
    let details = try result.unwrapImmediate().details
    #expect(details.object?["completed"]?.boolValue == true)
    let sessions = details.object?["sessions"]?.array ?? []
    #expect(sessions.count == 2)
    let timedOut = details.object?["timedOut"]?.array ?? []
    #expect(timedOut.isEmpty)
  }

  @Test func joinSessions_waitsThenReturnsWhenChildBecomesIdle() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let child = try await createChildSession(store: store, service: service, parentSessionID: parent.id)

    // Mark child as running.
    try await store.setSessionExecutionStatus(
      sessionID: .init(rawValue: child.id),
      status: .running,
    )

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    // After a short delay, mark the child as idle and add a final message.
    Task {
      try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
      _ = try await appendFinalAssistantMessage(store: store, sessionID: child.id, text: "Child finished after delay")
      try await store.setSessionExecutionStatus(
        sessionID: .init(rawValue: child.id),
        status: .idle,
      )
    }

    let result = try await tool.execute(
      toolCallId: "tc2",
      args: .object([
        "sessionIDs": .array([.string(child.id)]),
        "timeout": .number(30),
      ]),
    )

    let text = try textOutput(result)
    #expect(text.contains("All 1 session completed."))
    #expect(text.contains("Child finished after delay"))
    #expect(try result.unwrapImmediate().details.object?["completed"]?.boolValue == true)
  }

  @Test func joinSessions_timesOutWithPartialResults() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let child1 = try await createChildSession(store: store, service: service, parentSessionID: parent.id)
    let child2 = try await createChildSession(store: store, service: service, parentSessionID: parent.id)

    // child1 is idle with a final message; child2 is running.
    _ = try await appendFinalAssistantMessage(store: store, sessionID: child1.id, text: "Child 1 done early")
    try await store.setSessionExecutionStatus(
      sessionID: .init(rawValue: child2.id),
      status: .running,
    )

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    let result = try await tool.execute(
      toolCallId: "tc3",
      args: .object([
        "sessionIDs": .array([.string(child1.id), .string(child2.id)]),
        "timeout": .number(3), // Short timeout — child2 won't finish.
      ]),
    )

    let text = try textOutput(result)
    #expect(text.contains("1/2 completed, 1 timed out."))
    #expect(text.contains("Child 1 done early"))
    #expect(text.contains("still running"))
    #expect(text.contains("Use join_sessions again"))
    #expect(try result.unwrapImmediate().details.object?["completed"]?.boolValue == false)

    let timedOut = try result.unwrapImmediate().details.object?["timedOut"]?.array ?? []
    #expect(timedOut.count == 1)
    #expect(timedOut.first?.object?["sessionID"]?.stringValue == child2.id)
  }

  @Test func joinSessions_rejectsNonChildSession() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let unrelated = try await createParentSession(store: store, service: service) // Not a child

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    await #expect(throws: Error.self) {
      _ = try await tool.execute(
        toolCallId: "tc4",
        args: .object(["sessionIDs": .array([.string(unrelated.id)])]),
      )
    }
  }

  @Test func joinSessions_rejectsEmptySessionIDs() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    await #expect(throws: Error.self) {
      _ = try await tool.execute(
        toolCallId: "tc5",
        args: .object(["sessionIDs": .array([])]),
      )
    }
  }

  @Test func joinSessions_handlesSingleSession() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let child = try await createChildSession(store: store, service: service, parentSessionID: parent.id)

    _ = try await appendFinalAssistantMessage(store: store, sessionID: child.id, text: "Solo child done")

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    let result = try await tool.execute(
      toolCallId: "tc6",
      args: .object(["sessionIDs": .array([.string(child.id)])]),
    )

    let text = try textOutput(result)
    #expect(text.contains("All 1 session completed."))
    #expect(text.contains("Solo child done"))
  }

  @Test func joinSessions_handlesStoppedSession() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)
    let child = try await createChildSession(store: store, service: service, parentSessionID: parent.id)

    // Mark child as stopped (crashed/killed).
    _ = try await appendFinalAssistantMessage(store: store, sessionID: child.id, text: "Child was stopped")
    try await store.setSessionExecutionStatus(
      sessionID: .init(rawValue: child.id),
      status: .stopped,
    )

    let tool = try #require(await getJoinSessionsTool(service: service, parentSession: parent))

    let result = try await tool.execute(
      toolCallId: "tc7",
      args: .object(["sessionIDs": .array([.string(child.id)])]),
    )

    let text = try textOutput(result)
    #expect(text.contains("All 1 session completed."))
    #expect(text.contains("[stopped]"))
    #expect(text.contains("Child was stopped"))
  }

  @Test func joinSessions_toolIsAvailableInManagementTools() async throws {
    let (store, service) = try makeStoreAndService()
    let parent = try await createParentSession(store: store, service: service)

    let tool = await getJoinSessionsTool(service: service, parentSession: parent)
    #expect(tool != nil)
    #expect(tool?.tool.name == "join_sessions")
  }
}
