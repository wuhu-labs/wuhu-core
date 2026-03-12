import Foundation
import Testing
import WuhuSessionCoreTestingSupport
import WuhuLocalTools
@testable import WuhuSessionCore

@Suite struct LocalToolsTests {
  @Test func localProjectionReadsSessionTitleSemanticEntry() {
    let transcript = Transcript(
      entries: [
        .semantic(
          .init(
            id: UUID(),
            entry: AnySemanticEntry(SessionSemanticEntry.sessionTitleSet("V3 direction")),
            timestamp: .distantPast
          )
        )
      ]
    )

    let projection = LocalSessionProjection.project(from: transcript)
    #expect(projection.title == "V3 direction")
  }

  @Test func bashRunsCommandOnLocalMachine() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            toolCall("call-bash", "bash", args: .object([
              "command": .string("printf hello"),
            ])),
          ]
        ),
        .init(
          blocks: [
            .text("The command finished."),
          ]
        ),
      ],
      tools: LocalSessionFactory.makeLocalToolRegistry()
    )

    await harness.enqueueSteer("Run a quick bash command.")
    let state = await harness.waitUntilIdle(minimumTranscriptEntries: 4)

    #expect(state.transcript.debugSummary == [
      "user[steer]: Run a quick bash command.",
      "tool-call[call-bash]: bash",
      "tool-result[call-bash]: bash -> hello",
      "assistant[finished]: The command finished.",
    ])
    await harness.finish()
  }
}
