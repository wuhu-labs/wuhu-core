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

    await harness.send("Read the README.")
    let state = await harness.waitUntilIdle(minimumTranscriptEntries: 5)

    #expect(state.transcript.debugSummary == [
      "user: Read the README.",
      "assistant: I will read the README.",
      "tool-call[call-read]: read",
      "tool-result[call-read]: read -> # Wuhu Playground\n\nThis is a seeded virtual file tree for the playground app.\nUse the read tool to inspect files.",
      "assistant: The README says this is a seeded virtual file tree for the playground app.",
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

    await harness.send("Sleep for 2 minutes.")
    let waiting = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)
    #expect(waiting.activeToolCalls.count == 1)
    #expect(waiting.activeToolCalls[0].progress.isEmpty)

    await harness.advanceSleep(toolCallID: "call-sleep")
    let afterFirstMinute = await harness.tracker.waitUntil { state in
      state.activeToolCalls.first?.progress.count == 1
    }
    #expect(afterFirstMinute.transcript.debugSummary == [
      "user: Sleep for 2 minutes.",
      "assistant: Starting the sleep tool.",
      "tool-call[call-sleep]: sleep",
    ])

    await harness.advanceSleep(toolCallID: "call-sleep")
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 5)

    #expect(finished.transcript.debugSummary == [
      "user: Sleep for 2 minutes.",
      "assistant: Starting the sleep tool.",
      "tool-call[call-sleep]: sleep",
      "tool-result[call-sleep]: sleep -> Completed 2 minute sleep.",
      "assistant: The sleep completed.",
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

    await harness.send("Begin sleeping.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)

    await harness.send("Please note this steer message.")
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

    await harness.send("Start a sleep.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 3)
    await harness.stop()
    _ = await harness.waitUntilPaused()

    await harness.send("Actually do this instead.")
    await harness.resume()
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 6)

    #expect(finished.transcript.debugSummary == [
      "user: Start a sleep.",
      "assistant: I am going to sleep.",
      "tool-call[call-sleep]: sleep",
      "system[control]: User stopped execution.",
      "user: Actually do this instead.",
      "assistant: I picked up the resumed steer message.",
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

    await harness.send("Wait for the sleep.")
    _ = await harness.waitUntilWaitingForTools(minimumTranscriptEntries: 4)
    await harness.advanceSleep(toolCallID: "call-sleep")
    let finished = await harness.waitUntilIdle(minimumTranscriptEntries: 7)

    #expect(finished.transcript.debugSummary == [
      "user: Wait for the sleep.",
      "assistant: I will wait for the sleep tool.",
      "tool-call[call-sleep]: sleep",
      "tool-call[call-join]: join",
      "tool-result[call-sleep]: sleep -> Completed 1 minute sleep.",
      "tool-result[call-join]: join -> Woke because sleep finished.",
      "assistant: The join woke up after the tool completed.",
    ])
  }
}
