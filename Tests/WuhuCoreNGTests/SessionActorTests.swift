import Testing
@testable import WuhuCoreNG

@Suite struct SessionActorTests {
  @Test func nonPersistentReadToolRoundTrip() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I will read the README."),
            toolCall("call-read", "read", args: .object([
              "path": .string("/README.md"),
            ])),
          ]
        ),
        .init(
          blocks: [
            .text("The README says this is a seeded virtual file tree for the playground app."),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Read the README.")
    let state = await harness.waitUntilIdle(minimumTranscriptEntries: 5)

    #expect(state.transcript.debugSummary == [
      "user[steer]: Read the README.",
      "assistant[finished]: I will read the README.",
      "tool-call[call-read]: read",
      "tool-result[call-read]: read -> # Wuhu Playground\n\nThis is a seeded virtual file tree for the playground app.\nUse the read tool to inspect files.",
      "assistant[finished]: The README says this is a seeded virtual file tree for the playground app.",
    ])
  }

  @Test func persistentSleepReportsProgressButOnlyAppendsFinalResult() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("Starting the sleep tool."),
            toolCall("call-sleep", "sleep", args: .object([
              "minutes": .number(2),
            ])),
          ]
        ),
        .init(
          blocks: [
            .text("The sleep completed."),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Sleep for 2 minutes.")
    let waiting = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)
    #expect(waiting.activeToolCalls.count == 1)
    #expect(waiting.activeToolCalls[0].progress.isEmpty)

    await harness.advanceSleep(toolCallID: "call-sleep")
    let afterFirstMinute = await harness.tracker.waitUntil { state in
      state.activeToolCalls.first?.progress.count == 1
    }
    #expect(afterFirstMinute.transcript.debugSummary == [
      "user[steer]: Sleep for 2 minutes.",
      "assistant[finished]: Starting the sleep tool.",
      "tool-call[call-sleep]: sleep",
    ])

    await harness.advanceSleep(toolCallID: "call-sleep")
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 5)

    #expect(finished.transcript.debugSummary == [
      "user[steer]: Sleep for 2 minutes.",
      "assistant[finished]: Starting the sleep tool.",
      "tool-call[call-sleep]: sleep",
      "tool-result[call-sleep]: sleep -> Completed 2 minute sleep.",
      "assistant[finished]: The sleep completed.",
    ])
  }

  @Test func stopPausesAndPreservesQueuedMessages() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I am starting a long sleep."),
            toolCall("call-sleep", "sleep", args: .object([
              "minutes": .number(3),
            ])),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Begin sleeping.")
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
  }

  @Test func resumeDrainsQueuedSteerWork() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I am going to sleep."),
            toolCall("call-sleep", "sleep", args: .object([
              "minutes": .number(2),
            ])),
          ]
        ),
        .init(
          blocks: [
            .text("I picked up the resumed steer message."),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Start a sleep.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)
    await harness.stop()
    _ = await harness.waitUntilPaused()

    await harness.enqueueSteer("Actually do this instead.")
    await harness.resume()
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 6)

    #expect(finished.transcript.debugSummary == [
      "user[steer]: Start a sleep.",
      "assistant[finished]: I am going to sleep.",
      "tool-call[call-sleep]: sleep",
      "system[control]: User stopped execution.",
      "user[steer]: Actually do this instead.",
      "assistant[finished]: I picked up the resumed steer message.",
    ])
  }

  @Test func joinWakesWhenPersistentToolCompletes() async throws {
    let harness = await SessionHarness(
      turns: [
        .init(
          blocks: [
            .text("I will wait for the sleep tool."),
            toolCall("call-sleep", "sleep", args: .object([
              "minutes": .number(1),
            ])),
            toolCall("call-join", "join"),
          ]
        ),
        .init(
          blocks: [
            .text("The join woke up after the tool completed."),
          ]
        ),
      ]
    )

    await harness.enqueueSteer("Wait for the sleep.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 4)
    await harness.advanceSleep(toolCallID: "call-sleep")
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 7)

    #expect(finished.transcript.debugSummary == [
      "user[steer]: Wait for the sleep.",
      "assistant[finished]: I will wait for the sleep tool.",
      "tool-call[call-sleep]: sleep",
      "tool-call[call-join]: join",
      "tool-result[call-sleep]: sleep -> Completed 1 minute sleep.",
      "tool-result[call-join]: join -> Woke because sleep finished.",
      "assistant[finished]: The join woke up after the tool completed.",
    ])
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
  }

  @Test func stopCommitsDraftAsInterruptedAssistantText() async throws {
    let turn = ScriptedTurn(
      blocks: [
        .text("Partial answer."),
      ],
      streamedTextDeltas: ["Partial answer."],
      holdBeforeDone: true
    )

    let harness = await SessionHarness(
      turns: [
        turn,
      ]
    )

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
  }
}
