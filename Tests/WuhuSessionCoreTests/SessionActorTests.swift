import Foundation
import Testing
import WuhuSessionCoreTestingSupport
@testable import WuhuSessionCore

@Suite struct SessionActorTests {
  @Test func semanticEntriesDoNotEnterContextMessages() {
    let transcript = Transcript(
      entries: [
        .userMessage(
          .init(
            id: UUID(),
            text: "Hello",
            lane: .steer,
            timestamp: .distantPast
          )
        ),
        .semantic(
          .init(
            id: UUID(),
            entry: AnySemanticEntry(TestSemanticEntry.flagged),
            timestamp: .distantPast
          )
        ),
      ]
    )

    let messages = transcript.contextMessages(model: .init(id: "test", provider: .anthropic))
    #expect(messages.count == 1)
  }

  @Test func setSessionTitleAppendsSemanticEntry() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            toolCall("call-title", "set_session_title", args: .object([
              "title": .string("V3 direction"),
            ])),
          ]
        ),
        .init(
          blocks: [
            .text("Title updated."),
          ]
        ),
      ],
      tools: SessionSemanticTools.makeRegistry()
    )

    await harness.enqueueSteer("Set the title.")
    let state = await harness.waitUntilIdle(minimumTranscriptEntries: 5)

    #expect(state.transcript.debugSummary == [
      "user[steer]: Set the title.",
      "tool-call[call-title]: set_session_title",
      "tool-result[call-title]: set_session_title -> Session title set to \"V3 direction\".",
      "semantic: \(String(reflecting: SessionSemanticEntry.self))",
      "assistant[finished]: Title updated.",
    ])
    let semanticEntries = state.transcript.entries.compactMap { entry -> SessionSemanticEntry? in
      guard case let .semantic(record) = entry else { return nil }
      return record.entry.unwrap()
    }
    #expect(semanticEntries == [.sessionTitleSet("V3 direction")])
    await harness.finish()
  }

  @Test func inferenceStreamingPublishesDraftBeforeCommit() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("Streaming is live."),
          ],
          streamedTextDeltas: ["Streaming", " is", " live."]
        ),
      ]
    )

    await harness.enqueueSteer("Say something with streaming.")
    let drafting = await harness.waitUntilDraftText("Streaming is live.")
    #expect(drafting.transcript.debugSummary == [
      "user[steer]: Say something with streaming.",
    ])

    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 2)
    #expect(finished.assistantDraft == nil)
    #expect(finished.transcript.debugSummary == [
      "user[steer]: Say something with streaming.",
      "assistant[finished]: Streaming is live.",
    ])
    await harness.finish()
  }

  @Test func followUpDrainsAfterNoToolAssistantTurn() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("First answer."),
          ]
        ),
        .init(
          blocks: [
            .text("Follow-up handled."),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Start.")
    _ = await harness.waitUntilIdle(minimumTranscriptEntries: 2)

    await harness.enqueueFollowUp("Do one more thing.")
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 4)

    #expect(finished.transcript.debugSummary == [
      "user[steer]: Start.",
      "assistant[finished]: First answer.",
      "user[followUp]: Do one more thing.",
      "assistant[finished]: Follow-up handled.",
    ])
    let userEntries = finished.transcript.entries.compactMap { entry -> UserMessageEntry? in
      guard case let .userMessage(message) = entry else { return nil }
      return message
    }
    #expect(userEntries.map(\.lane) == [.steer, .followUp])
    await harness.finish()
  }

  @Test func stopPausesAndPreservesQueuedMessages() async throws {
    let runtimeController = ManualRuntimeToolController()
    let runtimeTool = await runtimeController.makeTool(named: "wait")

    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I am waiting."),
            toolCall("call-wait", "wait"),
          ]
        ),
      ],
      tools: .init(
        exposedTools: [runtimeTool.tool],
        executors: [runtimeTool.tool.name: runtimeTool]
      )
    )

    await harness.enqueueSteer("Begin waiting.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)

    await harness.enqueueSteer("Please note this steer message.")
    await harness.enqueueFollowUp("Remember to summarize later.")
    await harness.enqueueNotification("The outside world changed.")
    await harness.stop()

    let paused = await harness.waitUntilPaused()
    #expect(paused.steerQueue.map(\.text) == ["Please note this steer message."])
    #expect(paused.followUpQueue.map(\.text) == ["Remember to summarize later."])
    #expect(paused.notificationQueue.map(\.text) == ["The outside world changed."])
    #expect(paused.activeToolCalls.isEmpty)
    #expect(paused.transcript.debugSummary.last == "system[control]: User stopped execution.")
    await harness.finish()
  }

  @Test func resumeDrainsQueuedSteerWork() async throws {
    let runtimeController = ManualRuntimeToolController()
    let runtimeTool = await runtimeController.makeTool(named: "wait")

    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I am waiting."),
            toolCall("call-wait", "wait"),
          ]
        ),
        .init(
          blocks: [
            .text("I picked up the resumed steer message."),
          ]
        ),
      ],
      tools: .init(
        exposedTools: [runtimeTool.tool],
        executors: [runtimeTool.tool.name: runtimeTool]
      )
    )

    await harness.enqueueSteer("Start waiting.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)
    await harness.stop()
    _ = await harness.waitUntilPaused()

    await harness.enqueueSteer("Actually do this instead.")
    await harness.resume()
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 6)

    #expect(finished.transcript.debugSummary == [
      "user[steer]: Start waiting.",
      "assistant[finished]: I am waiting.",
      "tool-call[call-wait]: wait",
      "system[control]: User stopped execution.",
      "user[steer]: Actually do this instead.",
      "assistant[finished]: I picked up the resumed steer message.",
    ])
    await harness.finish()
  }

  @Test func stopCommitsDraftAsInterruptedAssistantText() async throws {
    let turn = ScriptedTurn(
      blocks: [
        .text("Partial answer."),
      ],
      streamedTextDeltas: ["Partial answer."],
      holdBeforeDone: true
    )

    let harness = await SessionHarness(turns: [turn])

    await harness.enqueueSteer("Start streaming.")
    _ = await harness.waitUntilDraftText("Partial answer.")
    await harness.stop()
    let paused = await harness.waitUntilPaused()

    #expect(paused.assistantDraft == nil)
    #expect(paused.transcript.debugSummary == [
      "user[steer]: Start streaming.",
      "assistant[interrupted]: Partial answer.",
      "system[control]: User stopped execution.",
    ])
    let assistantEntries = paused.transcript.entries.compactMap { entry -> AssistantTextEntry? in
      guard case let .assistantText(message) = entry else { return nil }
      return message
    }
    #expect(assistantEntries.map(\.completion) == [.interrupted])
    await harness.finish()
  }
}

private enum TestSemanticEntry: Sendable, Hashable, SemanticEntry {
  case flagged
}
