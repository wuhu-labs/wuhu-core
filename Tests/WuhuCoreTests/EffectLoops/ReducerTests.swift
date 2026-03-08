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

private func makeEntry(id: Int64 = 1, sessionID: String = "test") -> WuhuSessionEntry {
  WuhuSessionEntry(
    id: id,
    sessionID: sessionID,
    parentEntryID: nil,
    createdAt: Date(),
    payload: .custom(customType: "test", data: nil),
  )
}

// MARK: - Queue Reducer Tests

@Suite("reduceQueue")
struct QueueReducerTests {
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
    state.inference.lastError = "some error"

    let message = AssistantMessage(provider: .openai, model: "test")
    reduceInference(state: &state, action: .completed(message))

    #expect(state.inference.status == .idle)
    #expect(state.inference.retryCount == 0)
    #expect(state.inference.retryAfter == nil)
    #expect(state.inference.lastError == nil)
  }

  @Test("failed increments retry count and records error")
  func failed() {
    var state = makeState()
    state.inference.status = .running

    reduceInference(state: &state, action: .failed("timeout"))
    #expect(state.inference.retryCount == 1)
    #expect(state.inference.lastError == "timeout")

    reduceInference(state: &state, action: .failed("timeout again"))
    #expect(state.inference.retryCount == 2)
    #expect(state.inference.lastError == "timeout again")
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

  @Test("completed updates status")
  func completed() {
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    reduceTools(state: &state, action: .completed(id: "tc-1", status: .completed))
    #expect(state.tools.statuses["tc-1"] == .completed)
  }

  @Test("failed updates status to errored")
  func failed() {
    var state = makeState()
    state.tools.statuses["tc-1"] = .started
    reduceTools(state: &state, action: .failed(id: "tc-1", status: .errored))
    #expect(state.tools.statuses["tc-1"] == .errored)
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

// MARK: - WuhuBehavior Integration Tests

@Suite("WuhuBehavior")
struct WuhuBehaviorTests {
  @Test("reduce dispatches to correct sub-reducer")
  func reduceDispatches() {
    let behavior = WuhuBehavior()
    var state = makeState()

    // Queue action
    let backfill = SystemUrgentQueueBackfill(
      cursor: .init(rawValue: "10"),
      pending: [],
      journal: [],
    )
    behavior.reduce(state: &state, action: .queue(.systemUpdated(backfill)))
    #expect(state.queue.system.cursor.rawValue == "10")

    // Cost action
    behavior.reduce(state: &state, action: .cost(.pause))
    #expect(state.cost.isPaused == true)

    // Transcript action
    behavior.reduce(state: &state, action: .transcript(.append(makeEntry())))
    #expect(state.transcript.entries.count == 1)
  }

  @Test("nextEffect returns nil (stub)")
  func nextEffectStub() {
    let behavior = WuhuBehavior()
    var state = makeState()
    let effect = behavior.nextEffect(state: &state)
    #expect(effect == nil)
  }
}
