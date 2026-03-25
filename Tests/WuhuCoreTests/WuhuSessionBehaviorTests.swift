import Foundation
import Testing
import WuhuAI
import WuhuAPI
@testable import WuhuCore

struct WuhuSessionBehaviorTests {
  @Test func mountStateLoadsFromTypedCustomEntries() async throws {
    let mock = MockStreamFn(text: "unused")
    let harness = try TestHarness(mockLLM: mock)
    let session = try await harness.createSession(cwd: nil)

    let mount = WuhuMount(
      id: "mount-demo",
      sessionID: session.id,
      name: "workspace",
      path: "/tmp/demo",
      isPrimary: true,
      createdAt: Date(),
    )

    _ = try await harness.store.appendEntry(
      sessionID: session.id,
      payload: .knownCustom(.mountDeclared(mount)),
    )

    let behavior = WuhuSessionBehavior(
      sessionID: .init(rawValue: session.id),
      store: harness.store,
      runtimeConfig: WuhuSessionRuntimeConfig(),
      blobStore: harness.blobStore,
      streamFn: mock.streamFn,
    )

    let state = try await behavior.loadState()
    let primaryMount = try #require(state.mounts.primaryMount)
    #expect(primaryMount.id == mount.id)
    #expect(primaryMount.sessionID == mount.sessionID)
    #expect(primaryMount.name == "workspace")
    #expect(primaryMount.path == "/tmp/demo")
    #expect(primaryMount.isPrimary == true)
    #expect(state.session.cwd == "/tmp/demo")
  }
}
