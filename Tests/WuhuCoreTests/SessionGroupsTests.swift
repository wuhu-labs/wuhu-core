import Foundation
import Testing
import WuhuAI
import WuhuAPI
@testable import WuhuCore

struct SessionGroupsTests {
  @Test func defaultInboxGroupExistsAndNewSessionsUseIt() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let groups = try await store.listSessionGroups()
    let inbox = try #require(groups.first)
    #expect(groups.count == 1)
    #expect(inbox.id == WuhuSessionGroup.defaultID)
    #expect(inbox.name == "Inbox")
    #expect(inbox.isDefault)

    let session = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "gpt-5.4",
      reasoningEffort: nil,
      systemPrompt: "Test",
      cwd: nil,
      parentSessionID: nil,
    )
    #expect(session.sessionGroupID == WuhuSessionGroup.defaultID)
    #expect(session.profileName == nil)
  }

  @Test func sessionSummariesUseFirstUserTitleAndLastMessagePreview() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let focusGroup = try await store.createSessionGroup(name: "Focus", profileName: nil)

    let focusSession = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "gpt-5.4",
      reasoningEffort: nil,
      systemPrompt: "Test",
      cwd: nil,
      sessionGroupID: focusGroup.id,
      parentSessionID: nil,
      profileName: nil,
    )

    _ = try await store.appendEntry(
      sessionID: focusSession.id,
      payload: .message(.fromPi(.user("Need a rollout plan for session groups"))),
    )
    _ = try await store.appendEntry(
      sessionID: focusSession.id,
      payload: .message(.fromPi(.assistant(.init(
        provider: .openai,
        model: "gpt-5.4",
        content: [.text("Drafting the rollout now.")],
        stopReason: .stop,
      )))),
    )
    _ = try await store.appendEntry(
      sessionID: focusSession.id,
      payload: .message(.fromPi(.user("Latest note from me"))),
    )

    let inboxSession = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .anthropic,
      model: "claude-sonnet-4-6",
      reasoningEffort: nil,
      systemPrompt: "Test",
      cwd: nil,
      parentSessionID: nil,
    )
    _ = try await store.appendEntry(
      sessionID: inboxSession.id,
      payload: .message(.fromPi(.user("Inbox session should not leak into Focus"))),
    )

    let focusSummaries = try await store.listSessionSummaries(sessionGroupID: focusGroup.id)
    let summary = try #require(focusSummaries.first)
    #expect(focusSummaries.count == 1)
    #expect(summary.session.id == focusSession.id)
    #expect(summary.displayTitle == "Need a rollout plan for session groups")
    #expect(summary.firstUserMessageText == "Need a rollout plan for session groups")
    #expect(summary.lastMessageRole == .user)
    #expect(summary.lastMessageText == "Latest note from me")

    let inboxSummaries = try await store.listSessionSummaries(sessionGroupID: WuhuSessionGroup.defaultID)
    #expect(inboxSummaries.count == 1)
    #expect(inboxSummaries.first?.session.id == inboxSession.id)
  }

  @Test func profileSnapshotAppliesToFutureSessionsAndChildrenInheritIt() async throws {
    let workspaceRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-session-groups-\(UUID().uuidString.lowercased())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspaceRoot) }

    try makeProfileWorkspace(
      root: workspaceRoot,
      workspaceAgents: "workspace agents instructions",
      profiles: [
        ("research", "research profile instructions"),
        ("review", "review profile instructions"),
      ],
    )

    let harness = try TestHarness(
      mockLLM: MockStreamFn(text: "ok"),
      workspaceRoot: workspaceRoot.path,
    )

    let group = try await harness.service.createSessionGroup(name: "Research", profileName: "research")
    let firstSession = try await harness.createSession(sessionGroupID: group.id)
    #expect(firstSession.sessionGroupID == group.id)
    #expect(firstSession.profileName == "research")

    let firstAgentsText = try #require(await agentsContextText(from: harness.transcript(sessionID: firstSession.id)))
    #expect(firstAgentsText.contains("research profile instructions"))
    #expect(!firstAgentsText.contains("workspace agents instructions"))

    _ = try await harness.service.updateSessionGroup(id: group.id, name: "Research", profileName: "review")

    let secondSession = try await harness.createSession(sessionGroupID: group.id)
    #expect(secondSession.sessionGroupID == group.id)
    #expect(secondSession.profileName == "review")

    let childSession = try await harness.createSession(
      sessionGroupID: WuhuSessionGroup.defaultID,
      parentSessionID: secondSession.id,
    )
    #expect(childSession.sessionGroupID == group.id)
    #expect(childSession.profileName == "review")

    let persistedFirst = try await harness.store.getSession(id: firstSession.id)
    let persistedSecond = try await harness.store.getSession(id: secondSession.id)
    #expect(persistedFirst.profileName == "research")
    #expect(persistedSecond.profileName == "review")
  }
}

private func makeProfileWorkspace(
  root: URL,
  workspaceAgents: String,
  profiles: [(name: String, agents: String)],
) throws {
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try workspaceAgents.write(
    to: root.appendingPathComponent("AGENTS.md"),
    atomically: true,
    encoding: .utf8,
  )

  let profilesRoot = root.appendingPathComponent("_profiles", isDirectory: true)
  try FileManager.default.createDirectory(at: profilesRoot, withIntermediateDirectories: true)

  for profile in profiles {
    let profileRoot = profilesRoot.appendingPathComponent(profile.name, isDirectory: true)
    try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)
    try profile.agents.write(
      to: profileRoot.appendingPathComponent("AGENTS.md"),
      atomically: true,
      encoding: .utf8,
    )
  }
}

private func agentsContextText(from entries: [WuhuSessionEntry]) -> String? {
  for entry in entries {
    guard case let .custom(customType, data) = entry.payload else { continue }
    guard customType == WuhuCustomMessageTypes.agentsContext else { continue }
    guard case let .object(object)? = data else { continue }
    guard case let .string(text)? = object["text"] else { continue }
    return text
  }
  return nil
}
