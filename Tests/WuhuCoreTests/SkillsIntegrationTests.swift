import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore

struct SkillsIntegrationTests {
  @Test func mountContextLoadsSkillsFromMountPath() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-\(UUID().uuidString.lowercased())", isDirectory: true)
    let skillsDir = root.appendingPathComponent(".wuhu/skills/hello-skill", isDirectory: true)
    try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

    let skillFile = skillsDir.appendingPathComponent("SKILL.md")
    let text = """
    ---
    name: hello-skill
    description: A test skill.
    ---

    # Hello Skill
    """
    try text.write(to: skillFile, atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(at: root) }

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: root.path,
    )

    // Create a mount and emit mount context (skills are now injected as custom entries)
    let mount = try await store.createMount(
      sessionID: sessionID,
      name: "test-mount",
      path: root.path,
      isPrimary: true,
    )
    try await service.emitMountContext(sessionID: sessionID, mount: mount)

    let entries = try await store.getEntries(sessionID: sessionID)

    // Find the skills context custom entry
    let skillsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.skillsContext
      }
      return false
    }
    #expect(skillsEntry != nil, "Expected a skills context custom entry")

    if case let .custom(_, data) = skillsEntry?.payload {
      let skillsText = data?.object?["text"]?.stringValue ?? ""
      #expect(skillsText.contains("<available_skills>"))
      #expect(skillsText.contains("hello-skill"))
      #expect(skillsText.contains("A test skill."))
    }
  }

  @Test func workspaceContextLoadsSkillsFromWorkspaceRoot() async throws {
    let fm = FileManager.default
    let mountRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-mount-\(UUID().uuidString.lowercased())", isDirectory: true)
    let workspaceRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-ws-\(UUID().uuidString.lowercased())", isDirectory: true)
    try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)

    // Put a skill in the workspace root (skills/ directly under workspace root).
    let wsSkillDir = workspaceRoot.appendingPathComponent("skills/ws-skill", isDirectory: true)
    try fm.createDirectory(at: wsSkillDir, withIntermediateDirectories: true)
    try """
    ---
    name: ws-skill
    description: A workspace skill.
    ---
    # Workspace Skill
    """.write(to: wsSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    defer {
      try? fm.removeItem(at: mountRoot)
      try? fm.removeItem(at: workspaceRoot)
    }

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, workspaceRoot: workspaceRoot.path, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: mountRoot.path,
    )

    // Workspace-level skills are emitted during createSession when workspaceRoot is set.
    let entries = try await store.getEntries(sessionID: sessionID)

    let skillsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.skillsContext
      }
      return false
    }
    #expect(skillsEntry != nil, "Expected a workspace skills context custom entry")

    if case let .custom(_, data) = skillsEntry?.payload {
      let skillsText = data?.object?["text"]?.stringValue ?? ""
      #expect(skillsText.contains("<available_skills>"))
      #expect(skillsText.contains("ws-skill"))
      let source = data?.object?["source"]?.stringValue
      #expect(source == "workspace")
    }
  }

  @Test func mountSkillOverridesWorkspaceSkillWithSameName() async throws {
    let fm = FileManager.default
    let mountRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-mount-\(UUID().uuidString.lowercased())", isDirectory: true)
    let workspaceRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-ws-\(UUID().uuidString.lowercased())", isDirectory: true)

    // Workspace skill
    let wsSkillDir = workspaceRoot.appendingPathComponent("skills/shared-skill", isDirectory: true)
    try fm.createDirectory(at: wsSkillDir, withIntermediateDirectories: true)
    try """
    ---
    name: shared-skill
    description: Workspace version.
    ---
    # WS
    """.write(to: wsSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    // Mount-level skill with same name
    let mountSkillDir = mountRoot.appendingPathComponent(".wuhu/skills/shared-skill", isDirectory: true)
    try fm.createDirectory(at: mountSkillDir, withIntermediateDirectories: true)
    try """
    ---
    name: shared-skill
    description: Mount version.
    ---
    # Mount
    """.write(to: mountSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    defer {
      try? fm.removeItem(at: mountRoot)
      try? fm.removeItem(at: workspaceRoot)
    }

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, workspaceRoot: workspaceRoot.path, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: mountRoot.path,
    )

    // Create a mount and emit mount context (this emits mount-level skills)
    let mount = try await store.createMount(
      sessionID: sessionID,
      name: "test-mount",
      path: mountRoot.path,
      isPrimary: true,
    )
    try await service.emitMountContext(sessionID: sessionID, mount: mount)

    let entries = try await store.getEntries(sessionID: sessionID)

    // There should be two skills context entries: workspace-level + mount-level.
    // The mount-level entry should contain the mount version of shared-skill.
    let skillsEntries = entries.filter { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.skillsContext
      }
      return false
    }
    #expect(skillsEntries.count == 2, "Expected workspace and mount skills context entries")

    // The mount-level skills entry (source: "mount") should have the mount version.
    let mountSkillsEntry = skillsEntries.first { entry in
      if case let .custom(_, data) = entry.payload {
        return data?.object?["source"]?.stringValue == "mount"
      }
      return false
    }
    #expect(mountSkillsEntry != nil, "Expected mount-level skills entry")

    if case let .custom(_, data) = mountSkillsEntry?.payload {
      let skillsText = data?.object?["text"]?.stringValue ?? ""
      #expect(skillsText.contains("shared-skill"))
      #expect(skillsText.contains("Mount version."))
    }
  }

  @Test func emitMountContextViaRunnerLoadsAgentsAndSkills() async throws {
    // Set up an InMemoryRunner with AGENTS.md and a skill
    let runner = InMemoryRunner(id: .remote(name: "test-remote"))
    await runner.seedFile(
      path: "/remote-ws/AGENTS.md",
      content: "# Remote Project\n\nAlways use tabs.",
    )
    await runner.seedFile(
      path: "/remote-ws/AGENTS.local.md",
      content: "# Local Overrides\n\nDebug port: 9999",
    )
    await runner.seedDirectory(path: "/remote-ws/.wuhu/skills/deploy-skill")
    await runner.seedFile(
      path: "/remote-ws/.wuhu/skills/deploy-skill/SKILL.md",
      content: """
      ---
      name: deploy-skill
      description: Handles deployment to production.
      ---

      # Deploy Skill
      Run `make deploy` in the project root.
      """,
    )

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: "/remote-ws",
    )

    let mount = try await store.createMount(
      sessionID: sessionID,
      name: "remote-ws",
      path: "/remote-ws",
      isPrimary: true,
      runnerID: .remote(name: "test-remote"),
    )

    // Emit context via the runner
    try await service.emitMountContext(sessionID: sessionID, mount: mount, runner: runner)

    let entries = try await store.getEntries(sessionID: sessionID)

    // Check mount announcement
    let mountEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.mountContext
      }
      return false
    }
    #expect(mountEntry != nil, "Expected mount announcement")

    // Check AGENTS.md was loaded via runner
    let agentsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.agentsContext
      }
      return false
    }
    #expect(agentsEntry != nil, "Expected AGENTS.md context entry")
    if case let .custom(_, data) = agentsEntry?.payload {
      let text = data?.object?["text"]?.stringValue ?? ""
      #expect(text.contains("Always use tabs"))
      #expect(text.contains("Debug port: 9999"))
    }

    // Check skills loaded via runner
    let skillsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.skillsContext
      }
      return false
    }
    #expect(skillsEntry != nil, "Expected skills context entry")
    if case let .custom(_, data) = skillsEntry?.payload {
      let text = data?.object?["text"]?.stringValue ?? ""
      #expect(text.contains("deploy-skill"))
      #expect(text.contains("Handles deployment to production"))
    }
  }

  @Test func emitMountContextViaRunnerHandlesMissingFiles() async throws {
    // Runner with no AGENTS.md and no skills
    let runner = InMemoryRunner(id: .remote(name: "empty-runner"))
    await runner.seedDirectory(path: "/empty-ws")

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store, runnerRegistry: RunnerRegistry(runners: [LocalRunner()]))

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      cwd: "/empty-ws",
    )

    let mount = try await store.createMount(
      sessionID: sessionID,
      name: "empty-ws",
      path: "/empty-ws",
      isPrimary: true,
      runnerID: .remote(name: "empty-runner"),
    )

    // Should not throw even though AGENTS.md and skills don't exist
    try await service.emitMountContext(sessionID: sessionID, mount: mount, runner: runner)

    let entries = try await store.getEntries(sessionID: sessionID)

    // Should have mount announcement but no AGENTS.md or skills entries
    let mountEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.mountContext
      }
      return false
    }
    #expect(mountEntry != nil, "Expected mount announcement")

    let agentsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.agentsContext
      }
      return false
    }
    #expect(agentsEntry == nil, "Should not have AGENTS.md entry when file doesn't exist")

    let skillsEntry = entries.first { entry in
      if case let .custom(customType, _) = entry.payload {
        return customType == WuhuCustomMessageTypes.skillsContext
      }
      return false
    }
    #expect(skillsEntry == nil, "Should not have skills entry when no skills exist")
  }

  @Test func loadSkillFromContentParsesCorrectly() {
    let content = """
    ---
    name: test-skill
    description: Does something useful.
    ---

    # Test Skill Instructions
    """

    let skill = SkillsLoader.loadSkillFromContent(
      content,
      filePath: "/project/.wuhu/skills/test-skill/SKILL.md",
      source: "project",
    )
    #expect(skill != nil)
    #expect(skill?.name == "test-skill")
    #expect(skill?.description == "Does something useful.")
    #expect(skill?.source == "project")
    #expect(skill?.baseDir == "/project/.wuhu/skills/test-skill")
    #expect(skill?.filePath == "/project/.wuhu/skills/test-skill/SKILL.md")
  }

  @Test func loadSkillFromContentReturnsNilForNoDescription() {
    let content = """
    ---
    name: bad-skill
    ---

    # No description
    """

    let skill = SkillsLoader.loadSkillFromContent(
      content,
      filePath: "/project/.wuhu/skills/bad-skill/SKILL.md",
      source: "project",
    )
    #expect(skill == nil, "Skill without description should be nil")
  }
}
