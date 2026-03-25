import Foundation
import Testing
import WuhuAI
import WuhuAPI
@testable import WuhuCore

struct WuhuSessionBehaviorTests {
  @Test func mountStateLoadsFromTranscriptToolResults() async throws {
    let mock = MockStreamFn(text: "unused")
    let harness = try TestHarness(mockLLM: mock)
    let session = try await harness.createSession(cwd: nil)

    let toolResult = WuhuToolResultMessage(
      toolCallId: "tc-mount",
      toolName: WuhuAgentToolNames.mount,
      content: [.text(text: "Mounted 'workspace' at /tmp/demo", signature: nil)],
      details: .object([
        "mountID": .string("mount-demo"),
        "name": .string("workspace"),
        "path": .string("/tmp/demo"),
        "mountTemplateID": .null,
        "isPrimary": .bool(true),
        "runner": .string("local"),
      ]),
      isError: false,
      timestamp: Date(),
    )

    _ = try await harness.store.appendEntry(
      sessionID: session.id,
      payload: .message(.toolResult(toolResult)),
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
    #expect(primaryMount.id == "mount-demo")
    #expect(primaryMount.name == "workspace")
    #expect(primaryMount.path == "/tmp/demo")
    #expect(state.session.cwd == "/tmp/demo")
  }
}
