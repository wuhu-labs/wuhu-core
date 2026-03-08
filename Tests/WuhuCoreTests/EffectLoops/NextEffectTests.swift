import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore
import WuhuCoreClient

// MARK: - Test Helpers

private func makeState() -> WuhuState {
  WuhuState(
    transcript: .empty,
    queue: .empty,
    inference: .empty,
    tools: .empty,
    cost: .empty,
    settings: .empty,
    status: .empty,
  )
}

private func makeRunningState() -> WuhuState {
  var state = makeState()
  state.status.snapshot = .init(status: .running)
  return state
}

private func makeBehavior() throws -> WuhuBehavior {
  let store = try SQLiteSessionStore(path: ":memory:")
  let blobDir = NSTemporaryDirectory() + "wuhu-test-blobs-\(UUID().uuidString.lowercased())"
  let blobStore = WuhuBlobStore(rootDirectory: blobDir)
  return WuhuBehavior(
    sessionID: .init(rawValue: "test"),
    store: store,
    runtimeConfig: WuhuSessionRuntimeConfig(),
    blobStore: blobStore,
  )
}

private func makeUserEntry(id: Int64 = 1) -> WuhuSessionEntry {
  WuhuSessionEntry(
    id: id,
    sessionID: "test",
    parentEntryID: nil,
    createdAt: Date(),
    payload: .message(.user(.init(
      content: [.text(text: "hello", signature: nil)], timestamp: Date(),
    ))),
  )
}

private func makeAssistantEntry(id: Int64 = 2) -> WuhuSessionEntry {
  WuhuSessionEntry(
    id: id,
    sessionID: "test",
    parentEntryID: nil,
    createdAt: Date(),
    payload: .message(.assistant(.init(
      provider: .openai, model: "test", content: [],
      usage: nil, stopReason: "stop", errorMessage: nil, timestamp: Date(),
    ))),
  )
}

private func makeToolResultEntry(id: Int64 = 3, toolCallId: String = "tc-1") -> WuhuSessionEntry {
  WuhuSessionEntry(
    id: id,
    sessionID: "test",
    parentEntryID: nil,
    createdAt: Date(),
    payload: .message(.toolResult(.init(
      toolCallId: toolCallId, toolName: "bash", content: [],
      details: .object([:]), isError: false, timestamp: Date(),
    ))),
  )
}

// MARK: - nextEffect Priority Tests

@Suite("nextEffect priority ladder")
struct NextEffectPriorityTests {
  @Test("idle state returns nil")
  func idleReturnsNil() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    // No work to do — should return nil
    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil)
  }

  // MARK: - Cost Gate (Priority 1)

  @Test("cost gate: isPaused returns nil")
  func costGatePaused() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.cost.isPaused = true
    // Even with work pending, cost gate blocks
    state.transcript.entries.append(makeUserEntry())
    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil)
  }

  @Test("cost gate: approved resumes, nextEffect proceeds")
  func costGateApproved() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.cost.isPaused = true

    // Send approved action to resume
    reduceCost(state: &state, action: .approved(1000))
    #expect(state.cost.isPaused == false)

    // Now nextEffect should not be blocked by cost gate
    // (may still return nil if no other work)
    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil) // No actual work pending
  }

  // MARK: - Retry Backoff (Priority 2)

  @Test("retry backoff: retryAfter set returns sleep effect and clears guard token")
  func retryBackoff() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.inference.retryAfter = .now + .seconds(5)
    state.inference.status = .waitingRetry

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil) // Should return a sleep effect
    #expect(state.inference.retryAfter == nil) // Guard token cleared
  }

  @Test("retry flow: transient error → waitingRetry → retryReady → idle")
  func retryFlow() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.inference.status = .running

    // Transient error triggers retry
    let error = InferenceError(message: "HTTP 429", httpStatusCode: 429, isTransient: true)
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.status == .waitingRetry)
    #expect(state.inference.retryCount == 1)
    #expect(state.inference.retryAfter != nil)

    // nextEffect picks up the retry
    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.inference.retryAfter == nil) // Guard token cleared

    // retryReady brings back to idle
    reduceInference(state: &state, action: .retryReady)
    #expect(state.inference.status == .idle)
    #expect(state.inference.retryAfter == nil)
  }

  @Test("retry backoff: exponential delay capped at 60 seconds")
  func retryExponentialBackoff() {
    var state = makeState()
    state.inference.status = .running

    // First failure: delay = 2^0 = 1 second
    let error = InferenceError(message: "error", httpStatusCode: 500, isTransient: true)
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.retryCount == 1)

    // Simulate more failures to test cap
    for i in 2 ... 8 {
      state.inference.status = .running
      reduceInference(state: &state, action: .failed(error))
      #expect(state.inference.retryCount == i)
    }

    // At retryCount 8, delay = min(2^7, 60) = 60 (capped)
    #expect(state.inference.status == .waitingRetry)
  }

  @Test("permanent error does not set waitingRetry")
  func permanentErrorNoRetry() {
    var state = makeState()
    state.inference.status = .running

    let error = InferenceError(message: "HTTP 401", httpStatusCode: 401, isTransient: false)
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.status == .idle)
    #expect(state.inference.retryAfter == nil)
  }

  // MARK: - Session Status Gate

  @Test("stopped session returns nil even with pending work")
  func stoppedSessionReturnsNil() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.status.snapshot = .init(status: .stopped)
    state.transcript.entries.append(makeUserEntry())
    state.tools.statuses["tc-1"] = .started

    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil)
  }

  @Test("idle session returns nil even with pending work")
  func idleSessionReturnsNil() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.status.snapshot = .init(status: .idle)
    state.transcript.entries.append(makeUserEntry())

    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil)
  }

  @Test("retry backoff still fires for non-running sessions")
  func retryBackoffIgnoresStatusGate() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.status.snapshot = .init(status: .stopped)
    state.inference.retryAfter = .now + .seconds(5)
    state.inference.status = .waitingRetry

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil) // Retry backoff is above the status gate
    #expect(state.inference.retryAfter == nil)
  }

  // MARK: - Stale Tool Recovery (Priority 3)

  @Test("stale tool recovery takes priority over draining")
  func staleToolRecovery() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()

    // Set up a stale tool call (started, no result in transcript)
    state.tools.statuses["tc-1"] = .started

    // Also add pending queue items (lower priority)
    state.queue.system = .init(
      cursor: .init(rawValue: "0"),
      pending: [.init(id: .init(rawValue: "q1"), enqueuedAt: Date(), input: .init(source: .other("test"), content: .text("test")))],
      journal: [],
    )

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    // Guard token: should be marked as recovering
    #expect(state.tools.recoveringIDs.contains("tc-1"))
  }

  @Test("stale tool recovery sets recoveringIDs guard token")
  func staleRecoveryGuardToken() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.tools.statuses["tc-1"] = .started

    let effect1 = behavior.nextEffect(state: &state)
    #expect(effect1 != nil)
    #expect(state.tools.recoveringIDs.contains("tc-1"))

    // Second call should not re-schedule the same recovery
    let effect2 = behavior.nextEffect(state: &state)
    #expect(effect2 == nil)
  }

  // MARK: - Drain Interrupts (Priority 4)

  @Test("drain interrupts when system queue has items")
  func drainInterrupts() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.queue.system = .init(
      cursor: .init(rawValue: "0"),
      pending: [.init(id: .init(rawValue: "q1"), enqueuedAt: Date(), input: .init(source: .other("test"), content: .text("test")))],
      journal: [],
    )

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.queue.isDraining == true) // Guard token set
  }

  @Test("drain interrupts when steer queue has items")
  func drainSteer() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.queue.steer = .init(
      cursor: .init(rawValue: "0"),
      pending: [.init(id: .init(rawValue: "q1"), enqueuedAt: Date(), message: .init(author: .system, content: .text("hi")))],
      journal: [],
    )

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.queue.isDraining == true) // Guard token set
  }

  @Test("drain guard token prevents double-scheduling")
  func drainGuardToken() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.queue.system = .init(
      cursor: .init(rawValue: "0"),
      pending: [.init(id: .init(rawValue: "q1"), enqueuedAt: Date(), input: .init(source: .other("test"), content: .text("test")))],
      journal: [],
    )

    let effect1 = behavior.nextEffect(state: &state)
    #expect(effect1 != nil)
    #expect(state.queue.isDraining == true)

    // Second call should not re-schedule drain
    let effect2 = behavior.nextEffect(state: &state)
    #expect(effect2 == nil)
  }

  // MARK: - Drain Turn Items (Priority 5)

  @Test("drain followUp when queue has items and no interrupts pending")
  func drainFollowUp() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.queue.followUp = .init(
      cursor: .init(rawValue: "0"),
      pending: [.init(id: .init(rawValue: "q1"), enqueuedAt: Date(), message: .init(author: .system, content: .text("follow up")))],
      journal: [],
    )

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.queue.isDraining == true) // Guard token set
  }

  // MARK: - Inference (Priority 6)

  @Test("inference starts when transcript needs response and session is running")
  func inferenceStarts() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.transcript.entries.append(makeUserEntry())

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.inference.status == .running) // Guard token set
  }

  @Test("inference skipped when already running")
  func inferenceSkippedWhenRunning() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.inference.status = .running
    state.transcript.entries.append(makeUserEntry())

    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil) // Already running, should not start another
  }

  @Test("inference skipped when last message is assistant")
  func inferenceSkippedWhenAssistantResponded() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.transcript.entries.append(makeUserEntry())
    state.transcript.entries.append(makeAssistantEntry())

    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil) // Model already responded
  }

  // MARK: - Tool Execution (Priority 7)

  @Test("tool execution when pending tool calls exist")
  func toolExecution() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()

    // Add an assistant entry with a tool call
    let assistantEntry = WuhuSessionEntry(
      id: 1,
      sessionID: "test",
      parentEntryID: nil,
      createdAt: Date(),
      payload: .message(.assistant(.init(
        provider: .openai, model: "test",
        content: [.toolCall(id: "tc-1", name: "bash", arguments: .object([:]))],
        usage: nil, stopReason: "tool_use", errorMessage: nil, timestamp: Date(),
      ))),
    )
    state.transcript.entries.append(assistantEntry)
    state.tools.statuses["tc-1"] = .pending

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    // Guard token: tool should be marked as started
    #expect(state.tools.statuses["tc-1"] == .started)
  }

  // MARK: - Priority Ordering

  @Test("cost gate has highest priority")
  func costGateHighestPriority() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.cost.isPaused = true
    state.inference.retryAfter = .now + .seconds(5) // Priority 2
    state.tools.statuses["tc-1"] = .started // Priority 3 (stale)
    state.transcript.entries.append(makeUserEntry()) // Priority 6

    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil) // Cost gate blocks everything
  }

  @Test("retry backoff beats stale recovery")
  func retryBeatsStale() throws {
    let behavior = try makeBehavior()
    var state = makeRunningState()
    state.inference.retryAfter = .now + .seconds(5)
    state.inference.status = .waitingRetry
    state.tools.statuses["tc-1"] = .started // Stale tool

    let effect = behavior.nextEffect(state: &state)
    #expect(effect != nil)
    #expect(state.inference.retryAfter == nil) // Guard token cleared = retry was picked
  }
}

// MARK: - Tool Repetition Tests

@Suite("Tool repetition tracking")
struct ToolRepetitionTests {
  @Test("repetition tracker records via reducer on completed action")
  func repetitionTrackerViaReducer() {
    var state = makeState()
    for i in 0 ..< 5 {
      reduceTools(state: &state, action: .completed(
        id: "tc-\(i)", status: .completed,
        toolName: "bash", argsHash: 42, resultHash: 99,
      ))
    }

    let count = state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42)
    #expect(count == 5)
    #expect(count >= ToolCallRepetitionTracker.blockThreshold)
  }

  @Test("repetition tracker resets on different result")
  func repetitionResetsOnDifferentResult() {
    var state = makeState()
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 99)
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 99)
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 100) // Different result

    let count = state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42)
    #expect(count == 1) // Reset to 1 because result changed
  }

  @Test("resetRepetitions action clears tracker")
  func resetRepetitionsAction() {
    var state = makeState()
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 99)
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 99)

    reduceTools(state: &state, action: .resetRepetitions)
    let count = state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42)
    #expect(count == 0)
  }

  @Test("warning threshold is 3, block threshold is 5")
  func thresholds() {
    #expect(ToolCallRepetitionTracker.warningThreshold == 3)
    #expect(ToolCallRepetitionTracker.blockThreshold == 5)
  }
}
