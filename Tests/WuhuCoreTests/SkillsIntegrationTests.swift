import Foundation
import PiAI
import Testing
import WuhuAPI
import WuhuCore

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
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore)

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
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore, workspaceRoot: workspaceRoot.path)

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
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore, workspaceRoot: workspaceRoot.path)

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
}
