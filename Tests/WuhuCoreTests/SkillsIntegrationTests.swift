import Foundation
import Testing
import WuhuAPI
import WuhuCore

struct SkillsIntegrationTests {
  @Test func createSessionLoadsSkillsIntoHeader() async throws {
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

    let env = WuhuEnvironment(name: "local", type: .local, path: root.path)

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environmentID: nil,
      environment: env,
    )

    let entries = try await store.getEntries(sessionID: sessionID)
    guard let headerEntry = entries.first(where: { if case .header = $0.payload { true } else { false } }),
          case let .header(header) = headerEntry.payload
    else {
      Issue.record("Expected header entry")
      return
    }

    #expect(header.systemPrompt.contains("<available_skills>"))
    #expect(header.systemPrompt.contains("hello-skill"))

    let skills = WuhuSkills.decodeFromHeaderMetadata(header.metadata)
    #expect(skills.count == 1)
    #expect(skills.first?.name == "hello-skill")
    #expect(skills.first?.description == "A test skill.")
    #expect(skills.first?.filePath.hasSuffix("/.wuhu/skills/hello-skill/SKILL.md") == true)
  }

  @Test func createSessionLoadsSkillsFromWorkspaceRoot() async throws {
    let fm = FileManager.default
    let envRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-env-\(UUID().uuidString.lowercased())", isDirectory: true)
    let workspaceRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-ws-\(UUID().uuidString.lowercased())", isDirectory: true)
    try fm.createDirectory(at: envRoot, withIntermediateDirectories: true)

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
      try? fm.removeItem(at: envRoot)
      try? fm.removeItem(at: workspaceRoot)
    }

    let store = try SQLiteSessionStore(path: ":memory:")
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore, workspaceRoot: workspaceRoot.path)

    let env = WuhuEnvironment(name: "local", type: .local, path: envRoot.path)

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environmentID: nil,
      environment: env,
    )

    let entries = try await store.getEntries(sessionID: sessionID)
    guard let headerEntry = entries.first(where: { if case .header = $0.payload { true } else { false } }),
          case let .header(header) = headerEntry.payload
    else {
      Issue.record("Expected header entry")
      return
    }

    #expect(header.systemPrompt.contains("<available_skills>"))
    #expect(header.systemPrompt.contains("ws-skill"))

    let skills = WuhuSkills.decodeFromHeaderMetadata(header.metadata)
    #expect(skills.count == 1)
    #expect(skills.first?.name == "ws-skill")
    #expect(skills.first?.source == "workspace")
  }

  @Test func projectSkillOverridesWorkspaceSkillWithSameName() async throws {
    let fm = FileManager.default
    let envRoot = fm.temporaryDirectory.appendingPathComponent("wuhu-skills-env-\(UUID().uuidString.lowercased())", isDirectory: true)
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

    // Project skill with same name
    let projSkillDir = envRoot.appendingPathComponent(".wuhu/skills/shared-skill", isDirectory: true)
    try fm.createDirectory(at: projSkillDir, withIntermediateDirectories: true)
    try """
    ---
    name: shared-skill
    description: Project version.
    ---
    # Proj
    """.write(to: projSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    defer {
      try? fm.removeItem(at: envRoot)
      try? fm.removeItem(at: workspaceRoot)
    }

    let store = try SQLiteSessionStore(path: ":memory:")
    let blobStore = WuhuBlobStore(rootDirectory: NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString)")
    let service = WuhuService(store: store, blobStore: blobStore, workspaceRoot: workspaceRoot.path)

    let env = WuhuEnvironment(name: "local", type: .local, path: envRoot.path)

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environmentID: nil,
      environment: env,
    )

    let entries = try await store.getEntries(sessionID: sessionID)
    guard let headerEntry = entries.first(where: { if case .header = $0.payload { true } else { false } }),
          case let .header(header) = headerEntry.payload
    else {
      Issue.record("Expected header entry")
      return
    }

    let skills = WuhuSkills.decodeFromHeaderMetadata(header.metadata)
    #expect(skills.count == 1)
    #expect(skills.first?.name == "shared-skill")
    // Project skill should override the workspace skill.
    #expect(skills.first?.description == "Project version.")
    #expect(skills.first?.source == "project")
  }
}
