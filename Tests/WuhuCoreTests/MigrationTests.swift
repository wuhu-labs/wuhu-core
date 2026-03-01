import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

/// Verifies that the v6 migration creates the expected schema and that the
/// mount template / mount / session CRUD works end-to-end on a fresh database.
struct MigrationTests {
  @Test func freshDatabaseCreatesExpectedTables() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    // Mount templates CRUD
    let mt = try await store.createMountTemplate(.init(
      name: "test-template",
      type: .folder,
      templatePath: "/tmp/template",
      workspacesPath: "/tmp/workspaces",
      startupScript: "./startup.sh",
    ))
    #expect(mt.name == "test-template")
    #expect(mt.type == .folder)
    #expect(mt.templatePath == "/tmp/template")
    #expect(mt.workspacesPath == "/tmp/workspaces")
    #expect(mt.startupScript == "./startup.sh")

    let templates = try await store.listMountTemplates()
    #expect(templates.count == 1)
    #expect(templates.first?.id == mt.id)

    let fetched = try await store.getMountTemplate(identifier: mt.name)
    #expect(fetched.id == mt.id)

    // Session creation with optional cwd (no environment columns)
    let session = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "test-model",
      reasoningEffort: nil,
      systemPrompt: "Test",
      cwd: "/workspace",
      parentSessionID: nil,
    )
    #expect(session.cwd == "/workspace")
    #expect(session.provider == .openai)
    #expect(session.model == "test-model")

    // Session without cwd (pure chat)
    let chatSession = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .anthropic,
      model: "chat-model",
      reasoningEffort: nil,
      systemPrompt: "Chat",
      cwd: nil,
      parentSessionID: nil,
    )
    #expect(chatSession.cwd == nil)

    // Mounts CRUD
    let mount = try await store.createMount(
      sessionID: session.id,
      name: "primary",
      path: "/workspace",
      mountTemplateID: mt.id,
      isPrimary: true,
    )
    #expect(mount.sessionID == session.id)
    #expect(mount.name == "primary")
    #expect(mount.path == "/workspace")
    #expect(mount.mountTemplateID == mt.id)
    #expect(mount.isPrimary == true)

    let mounts = try await store.listMounts(sessionID: session.id)
    #expect(mounts.count == 1)
    #expect(mounts.first?.id == mount.id)

    let primary = try await store.getPrimaryMount(sessionID: session.id)
    #expect(primary?.id == mount.id)

    // Secondary mount
    let secondary = try await store.createMount(
      sessionID: session.id,
      name: "secondary",
      path: "/extra",
      isPrimary: false,
    )
    #expect(secondary.isPrimary == false)
    #expect(secondary.mountTemplateID == nil)

    let allMounts = try await store.listMounts(sessionID: session.id)
    #expect(allMounts.count == 2)
  }

  @Test func sessionCwdCanBeUpdated() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let session = try await store.createSession(
      sessionID: UUID().uuidString.lowercased(),
      provider: .openai,
      model: "test",
      reasoningEffort: nil,
      systemPrompt: "Test",
      cwd: nil,
      parentSessionID: nil,
    )
    #expect(session.cwd == nil)

    try await store.setSessionCwd(sessionID: session.id, cwd: "/new-workspace")
    let updated = try await store.getSession(id: session.id)
    #expect(updated.cwd == "/new-workspace")
  }

  @Test func mountTemplateUpdateAndDelete() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let mt = try await store.createMountTemplate(.init(
      name: "updatable",
      type: .folder,
      templatePath: "/old/path",
      workspacesPath: "/old/workspaces",
    ))

    let updated = try await store.updateMountTemplate(
      identifier: mt.id,
      request: .init(name: "renamed", templatePath: "/new/path"),
    )
    #expect(updated.name == "renamed")
    #expect(updated.templatePath == "/new/path")
    #expect(updated.workspacesPath == "/old/workspaces") // unchanged

    try await store.deleteMountTemplate(identifier: updated.id)
    let remaining = try await store.listMountTemplates()
    #expect(remaining.isEmpty)
  }
}
