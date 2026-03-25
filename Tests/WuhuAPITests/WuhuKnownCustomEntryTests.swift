import Foundation
import Testing
import WuhuAPI

struct WuhuKnownCustomEntryTests {
  @Test func mountDeclaredRoundTripsThroughPayloadCompatibilityLayer() {
    let original = WuhuKnownCustomEntry.mountDeclared(.init(
      id: "mount-1",
      sessionID: "session-1",
      name: "workspace",
      path: "/tmp/workspace",
      isPrimary: true,
      createdAt: Date(timeIntervalSince1970: 1234.0),
    ))

    let payload = WuhuEntryPayload.knownCustom(original)
    let decoded = payload.knownCustomEntry

    #expect(decoded == original)
  }

  @Test func mountContextRoundTripsThroughPayloadCompatibilityLayer() {
    let original = WuhuKnownCustomEntry.mountContext(.init(
      mountID: "mount-1",
      name: "workspace",
      path: "/tmp/workspace",
      text: "Mounted 'workspace' at /tmp/workspace",
    ))

    let payload = WuhuEntryPayload.knownCustom(original)
    let decoded = payload.knownCustomEntry

    #expect(decoded == original)
  }

  @Test func llmRetryRoundTripsThroughPayloadCompatibilityLayer() {
    let original = WuhuKnownCustomEntry.llmRetry(.init(
      purpose: "inference",
      retryIndex: 2,
      maxRetries: 5,
      backoffSeconds: 1.5,
      error: "overloaded",
    ))

    let payload = WuhuEntryPayload.knownCustom(original)
    let decoded = payload.knownCustomEntry

    #expect(decoded == original)
  }
}
