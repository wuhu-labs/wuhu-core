import Foundation
import PiAI
import Testing
import WuhuAPI
@testable import WuhuCore

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

private func makeEntry(
  id: Int64 = 1,
  sessionID: String = "test",
  payload: WuhuEntryPayload = .custom(customType: "test", data: nil),
) -> WuhuSessionEntry {
  WuhuSessionEntry(
    id: id,
    sessionID: sessionID,
    parentEntryID: nil,
    createdAt: Date(),
    payload: payload,
  )
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

// MARK: - Queue Reducer Tests

@Suite("reduceQueue")
struct QueueReducerTests {
  @Test("drainFinished clears isDraining guard token")
  func drainFinished() {
    var state = makeState()
    state.queue.isDraining = true
    reduceQueue(state: &state, action: .drainFinished)
    #expect(state.queue.isDraining == false)
  }

  @Test("systemUpdated replaces system queue")
  func systemUpdated() {
    var state = makeState()
    let backfill = SystemUrgentQueueBackfill(
      cursor: .init(rawValue: "42"),
      pending: [],
      journal: [],
    )
    reduceQueue(state: &state, action: .systemUpdated(backfill))
    #expect(state.queue.system.cursor.rawValue == "42")
  }

  @Test("steerUpdated replaces steer queue")
  func steerUpdated() {
    var state = makeState()
    let backfill = UserQueueBackfill(
      cursor: .init(rawValue: "7"),
      pending: [],
      journal: [],
    )
    reduceQueue(state: &state, action: .steerUpdated(backfill))
    #expect(state.queue.steer.cursor.rawValue == "7")
  }

  @Test("followUpUpdated replaces followUp queue")
  func followUpUpdated() {
    var state = makeState()
    let backfill = UserQueueBackfill(
      cursor: .init(rawValue: "99"),
      pending: [],
      journal: [],
    )
    reduceQueue(state: &state, action: .followUpUpdated(backfill))
    #expect(state.queue.followUp.cursor.rawValue == "99")
  }

  @Test("queue update resets .failed inference to .idle")
  func queueUpdateResetsFailedInference() {
    var state = makeState()
    state.inference.status = .failed
    state.inference.retryCount = 5
    state.inference.lastError = InferenceError(message: "bad key", httpStatusCode: 401, isTransient: false)

    let backfill = UserQueueBackfill(
      cursor: .init(rawValue: "1"),
      pending: [],
      journal: [],
    )
    reduceQueue(state: &state, action: .followUpUpdated(backfill))
    #expect(state.inference.status == .idle)
    #expect(state.inference.retryCount == 0)
    #expect(state.inference.lastError == nil)
  }

  @Test("queue update does not reset non-failed inference status")
  func queueUpdateDoesNotResetRunning() {
    var state = makeState()
    state.inference.status = .running

    let backfill = UserQueueBackfill(
      cursor: .init(rawValue: "1"),
      pending: [],
      journal: [],
    )
    reduceQueue(state: &state, action: .followUpUpdated(backfill))
    #expect(state.inference.status == .running) // Unchanged
  }
}

// MARK: - Inference Reducer Tests

@Suite("reduceInference")
struct InferenceReducerTests {
  @Test("started transitions to running")
  func started() {
    var state = makeState()
    reduceInference(state: &state, action: .started)
    #expect(state.inference.status == .running)
    #expect(state.inference.lastError == nil)
  }

  @Test("completed resets to idle with zero retry count")
  func completed() {
    var state = makeState()
    state.inference.status = .running
    state.inference.retryCount = 3
    state.inference.lastError = InferenceError(message: "some error", httpStatusCode: nil, isTransient: false)

    let message = AssistantMessage(provider: .openai, model: "test")
    reduceInference(state: &state, action: .completed(message))

    #expect(state.inference.status == .idle)
    #expect(state.inference.retryCount == 0)
    #expect(state.inference.retryAfter == nil)
    #expect(state.inference.lastError == nil)
  }

  @Test("failed with transient error sets waitingRetry and retryAfter")
  func failedTransient() {
    var state = makeState()
    state.inference.status = .running

    let error = InferenceError(message: "HTTP 429", httpStatusCode: 429, isTransient: true)
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.retryCount == 1)
    #expect(state.inference.status == .waitingRetry)
    #expect(state.inference.retryAfter != nil)
    #expect(state.inference.lastError == error)
    #expect(state.inference.lastError?.httpStatusCode == 429)

    // Second transient failure increments retry count
    let error2 = InferenceError(message: "timeout again", httpStatusCode: nil, isTransient: true)
    state.inference.status = .running
    reduceInference(state: &state, action: .failed(error2))
    #expect(state.inference.retryCount == 2)
    #expect(state.inference.status == .waitingRetry)
    #expect(state.inference.lastError == error2)
  }

  @Test("failed with permanent error transitions to .failed terminal state")
  func failedPermanent() {
    var state = makeState()
    state.inference.status = .running

    let error = InferenceError(message: "HTTP 401", httpStatusCode: 401, isTransient: false)
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.retryCount == 1)
    #expect(state.inference.status == .failed)
    #expect(state.inference.retryAfter == nil)
    #expect(state.inference.lastError?.httpStatusCode == 401)
    #expect(state.inference.lastError?.isTransient == false)
  }

  @Test("transient error exhausting retry budget transitions to .failed")
  func failedTransientExhausted() {
    var state = makeState()
    let error = InferenceError(message: "HTTP 500", httpStatusCode: 500, isTransient: true)

    // Exhaust the retry budget (maxInferenceRetries = 10)
    for _ in 0 ..< 10 {
      state.inference.status = .running
      reduceInference(state: &state, action: .failed(error))
      #expect(state.inference.status == .waitingRetry)
      state.inference.retryAfter = nil
    }

    // 11th failure should exceed budget and transition to .failed
    state.inference.status = .running
    reduceInference(state: &state, action: .failed(error))
    #expect(state.inference.status == .failed)
    #expect(state.inference.retryAfter == nil)
  }

  @Test("retryReady clears retryAfter and goes idle")
  func retryReady() {
    var state = makeState()
    state.inference.status = .waitingRetry
    state.inference.retryAfter = .now + .seconds(5)

    reduceInference(state: &state, action: .retryReady)
    #expect(state.inference.status == .idle)
    #expect(state.inference.retryAfter == nil)
  }

  @Test("delta does not change state")
  func delta() {
    var state = makeState()
    state.inference.status = .running
    let before = state
    reduceInference(state: &state, action: .delta("hello"))
    #expect(state == before)
  }
}

// MARK: - InferenceError Classification Tests

@Suite("InferenceError.from")
struct InferenceErrorClassificationTests {
  @Test("PiAI 429 is transient")
  func piAI429() {
    let error = InferenceError.from(PiAIError.httpStatus(code: 429, body: "rate limited"))
    #expect(error.httpStatusCode == 429)
    #expect(error.isTransient == true)
  }

  @Test("PiAI 500/502/503/529 are transient")
  func piAIServerErrors() {
    for code in [500, 502, 503, 529] {
      let error = InferenceError.from(PiAIError.httpStatus(code: code, body: nil))
      #expect(error.httpStatusCode == code)
      #expect(error.isTransient == true)
    }
  }

  @Test("PiAI 401 is not transient")
  func piAI401() {
    let error = InferenceError.from(PiAIError.httpStatus(code: 401, body: "unauthorized"))
    #expect(error.httpStatusCode == 401)
    #expect(error.isTransient == false)
  }

  @Test("PiAI 400 is not transient")
  func piAI400() {
    let error = InferenceError.from(PiAIError.httpStatus(code: 400, body: "bad request"))
    #expect(error.httpStatusCode == 400)
    #expect(error.isTransient == false)
  }

  @Test("non-PiAI error is not transient")
  func genericError() {
    struct SomeError: Error {}
    let error = InferenceError.from(SomeError())
    #expect(error.httpStatusCode == nil)
    #expect(error.isTransient == false)
  }
}

// MARK: - Tools Reducer Tests

@Suite("reduceTools")
struct ToolsReducerTests {
  @Test("willExecute marks tool as started")
  func willExecute() {
    var state = makeState()
    let call = ToolCall(id: "tc-1", name: "bash", arguments: .object([:]))
    reduceTools(state: &state, action: .willExecute(call))
    #expect(state.tools.statuses["tc-1"] == .started)
  }

  @Test("completed updates status and records repetition")
  func completed() {
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    reduceTools(state: &state, action: .completed(
      id: "tc-1", status: .completed,
      toolName: "bash", argsHash: 42, resultHash: 99,
    ))
    #expect(state.tools.statuses["tc-1"] == .completed)
    #expect(state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42) == 1)
  }

  @Test("failed updates status to errored and records repetition")
  func failed() {
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    reduceTools(state: &state, action: .failed(id: "tc-1", status: .errored, toolName: "bash", argsHash: 42))
    #expect(state.tools.statuses["tc-1"] == .errored)
    #expect(state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42) == 1)
  }

  @Test("completed clears recoveringIDs")
  func completedClearsRecovering() {
    var state = makeState()
    state.tools.recoveringIDs.insert("tc-1")
    reduceTools(state: &state, action: .completed(
      id: "tc-1", status: .completed,
      toolName: "bash", argsHash: 0, resultHash: 0,
    ))
    #expect(!state.tools.recoveringIDs.contains("tc-1"))
  }

  @Test("failed clears recoveringIDs")
  func failedClearsRecovering() {
    var state = makeState()
    state.tools.recoveringIDs.insert("tc-1")
    reduceTools(state: &state, action: .failed(id: "tc-1", status: .errored, toolName: "bash", argsHash: 0))
    #expect(!state.tools.recoveringIDs.contains("tc-1"))
  }

  @Test("resetRepetitions clears tracker")
  func resetRepetitions() {
    var state = makeState()
    state.tools.repetitionTracker.record(toolName: "bash", argsHash: 42, resultHash: 99)
    #expect(state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42) == 1)

    reduceTools(state: &state, action: .resetRepetitions)
    #expect(state.tools.repetitionTracker.preflightCount(toolName: "bash", argsHash: 42) == 0)
  }
}

// MARK: - Cost Reducer Tests

@Suite("reduceCost")
struct CostReducerTests {
  @Test("spent deducts from budget and pauses when exhausted")
  func spentExhaustsBudget() {
    var state = makeState()
    state.cost.budgetRemaining = 100

    reduceCost(state: &state, action: .spent(60))
    #expect(state.cost.totalSpent == 60)
    #expect(state.cost.budgetRemaining == 40)
    #expect(state.cost.isPaused == false)

    reduceCost(state: &state, action: .spent(50))
    #expect(state.cost.totalSpent == 110)
    #expect(state.cost.budgetRemaining == -10)
    #expect(state.cost.isPaused == true)
  }

  @Test("spent with no budget does not pause")
  func spentNoBudget() {
    var state = makeState()
    reduceCost(state: &state, action: .spent(1000))
    #expect(state.cost.totalSpent == 1000)
    #expect(state.cost.budgetRemaining == nil)
    #expect(state.cost.isPaused == false)
  }

  @Test("approved adds budget and resumes")
  func approved() {
    var state = makeState()
    state.cost.isPaused = true
    state.cost.budgetRemaining = -10

    reduceCost(state: &state, action: .approved(200))
    #expect(state.cost.budgetRemaining == 190)
    #expect(state.cost.isPaused == false)
  }

  @Test("approved with nil budget starts from zero")
  func approvedFromNil() {
    var state = makeState()
    reduceCost(state: &state, action: .approved(500))
    #expect(state.cost.budgetRemaining == 500)
    #expect(state.cost.isPaused == false)
  }

  @Test("pause and resume toggle isPaused")
  func pauseResume() {
    var state = makeState()
    reduceCost(state: &state, action: .pause)
    #expect(state.cost.isPaused == true)
    reduceCost(state: &state, action: .resume)
    #expect(state.cost.isPaused == false)
  }
}

// MARK: - Transcript Reducer Tests

@Suite("reduceTranscript")
struct TranscriptReducerTests {
  @Test("append adds entry")
  func appendEntry() {
    var state = makeState()
    let entry = makeEntry()
    reduceTranscript(state: &state, action: .append(entry))
    #expect(state.transcript.entries.count == 1)
    #expect(state.transcript.entries[0].id == entry.id)
  }

  @Test("append preserves order")
  func appendOrder() {
    var state = makeState()
    reduceTranscript(state: &state, action: .append(makeEntry(id: 1)))
    reduceTranscript(state: &state, action: .append(makeEntry(id: 2)))
    reduceTranscript(state: &state, action: .append(makeEntry(id: 3)))
    #expect(state.transcript.entries.map(\.id) == [1, 2, 3])
  }

  @Test("compactionFinished clears isCompacting guard token")
  func compactionFinished() {
    var state = makeState()
    state.transcript.isCompacting = true
    reduceTranscript(state: &state, action: .compactionFinished)
    #expect(state.transcript.isCompacting == false)
  }
}

// MARK: - Settings Reducer Tests

@Suite("reduceSettings")
struct SettingsReducerTests {
  @Test("updated replaces snapshot")
  func updated() {
    var state = makeState()
    let snapshot = SessionSettingsSnapshot(
      effectiveModel: .init(provider: .anthropic, id: "claude-4"),
    )
    reduceSettings(state: &state, action: .updated(snapshot))
    #expect(state.settings.snapshot.effectiveModel.id == "claude-4")
  }
}

// MARK: - Status Reducer Tests

@Suite("reduceStatus")
struct StatusReducerTests {
  @Test("updated replaces snapshot")
  func updated() {
    var state = makeState()
    let snapshot = SessionStatusSnapshot(status: .running)
    reduceStatus(state: &state, action: .updated(snapshot))
    #expect(state.status.snapshot.status == .running)
  }
}

// MARK: - State Query Tests (needsInference, staleToolCallIDs)

@Suite("WuhuBehavior state queries")
struct WuhuBehaviorStateQueryTests {
  @Test("needsInference returns true when last message is user")
  func needsInferenceUser() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.transcript.entries.append(makeEntry(payload: .message(.user(.init(
      content: [.text(text: "hello", signature: nil)], timestamp: Date(),
    )))))
    #expect(behavior.needsInference(state: state) == true)
  }

  @Test("needsInference returns true when last message is tool result")
  func needsInferenceToolResult() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.transcript.entries.append(makeEntry(payload: .message(.toolResult(.init(
      toolCallId: "tc-1", toolName: "bash", content: [], details: .object([:]), isError: false, timestamp: Date(),
    )))))
    #expect(behavior.needsInference(state: state) == true)
  }

  @Test("needsInference returns false when last message is assistant")
  func needsInferenceAssistant() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.transcript.entries.append(makeEntry(payload: .message(.assistant(.init(
      provider: .openai, model: "test", content: [], usage: nil, stopReason: "stop",
      errorMessage: nil, timestamp: Date(),
    )))))
    #expect(behavior.needsInference(state: state) == false)
  }

  @Test("needsInference returns false for empty transcript")
  func needsInferenceEmpty() throws {
    let behavior = try makeBehavior()
    let state = makeState()
    #expect(behavior.needsInference(state: state) == false)
  }

  @Test("staleToolCallIDs finds orphaned tool calls")
  func staleToolCallIDs() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    state.tools.statuses["tc-2"] = .pending // pending is not stale — it hasn't been picked up yet
    state.tools.statuses["tc-3"] = .completed

    let stale = behavior.staleToolCallIDs(in: state)
    #expect(stale == ["tc-1"]) // Only started (not pending) is stale
  }

  @Test("staleToolCallIDs excludes tool calls currently recovering")
  func staleExcludesRecovering() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    state.tools.recoveringIDs.insert("tc-1")

    let stale = behavior.staleToolCallIDs(in: state)
    #expect(stale.isEmpty)
  }

  @Test("staleToolCallIDs excludes tool calls with results in transcript")
  func staleExcludesWithResults() throws {
    let behavior = try makeBehavior()
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    state.transcript.entries.append(makeEntry(payload: .message(.toolResult(.init(
      toolCallId: "tc-1", toolName: "bash", content: [], details: .object([:]), isError: false, timestamp: Date(),
    )))))

    let stale = behavior.staleToolCallIDs(in: state)
    #expect(stale.isEmpty)
  }
}
