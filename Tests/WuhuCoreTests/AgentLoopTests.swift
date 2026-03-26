import Foundation
import Testing
import WuhuAI
@testable import WuhuCore

struct AgentLoopTests {
  @Test func failureCleanupDoesNotFlushAcceptedState() async throws {
    let store = FailureCleanupStore(
      durableState: .init(acceptedCount: 0, needsInference: false),
    )
    let behavior = FailureCleanupBehavior(store: store)
    let loop = try await AgentLoop(behavior: behavior, initialState: behavior.loadState())

    let startTask = Task { () -> (any Error)? in
      do {
        try await loop.start()
        return nil
      } catch {
        return error
      }
    }

    await loop.send(.accept)
    await store.waitForFirstPersistStart()

    let error = try #require(await startTask.value)
    #expect(error is FailureCleanupError)

    let durableState = await store.loadState()
    #expect(durableState.acceptedCount == 0)
    #expect(durableState.needsInference == false)
  }
}

private enum FailureCleanupAction: Sendable {
  case accept
}

private enum FailureCleanupError: Error {
  case inferenceFailed
}

private struct FailureCleanupState: Sendable, Equatable {
  var acceptedCount: Int
  var needsInference: Bool
}

private actor FailureCleanupStore {
  private var durableState: FailureCleanupState
  private var firstPersistStarted = false
  private var firstPersistConsumed = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(durableState: FailureCleanupState) {
    self.durableState = durableState
  }

  func loadState() -> FailureCleanupState {
    durableState
  }

  func persist(_ newState: FailureCleanupState) async throws -> FailureCleanupState {
    if !firstPersistConsumed {
      firstPersistConsumed = true
      firstPersistStarted = true
      let waiters = waiters
      self.waiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }

      try await Task.sleep(nanoseconds: 60_000_000_000)
    }

    durableState = newState
    return newState
  }

  func waitForFirstPersistStart() async {
    guard !firstPersistStarted else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private struct FailureCleanupBehavior: AgentBehavior {
  typealias State = FailureCleanupState
  typealias PersistenceDiff = FailureCleanupState
  typealias StreamAction = String
  typealias ExternalAction = FailureCleanupAction
  typealias ToolResult = String

  let store: FailureCleanupStore

  func loadState() async throws -> FailureCleanupState {
    await store.loadState()
  }

  func diff(from oldState: FailureCleanupState, to newState: FailureCleanupState) -> FailureCleanupState? {
    oldState == newState ? nil : newState
  }

  func persist(
    _ diff: FailureCleanupState,
    from _: FailureCleanupState,
    to _: FailureCleanupState,
  ) async throws -> FailureCleanupState {
    try await store.persist(diff)
  }

  func handle(_ action: FailureCleanupAction, state: inout FailureCleanupState) {
    switch action {
    case .accept:
      state.acceptedCount += 1
      state.needsInference = true
    }
  }

  func drainInterruptItems(state _: inout FailureCleanupState) -> Bool {
    false
  }

  func drainTurnItems(state _: inout FailureCleanupState) -> Bool {
    false
  }

  func buildContext(state _: FailureCleanupState) -> Context {
    Context(messages: [])
  }

  func infer(
    context _: Context,
    stream _: AgentStreamSink<String>,
  ) async throws -> AssistantMessage {
    throw FailureCleanupError.inferenceFailed
  }

  func persistAssistantEntry(
    _: AssistantMessage,
    state _: inout FailureCleanupState,
  ) {}

  func toolWillExecute(
    _: ToolCall,
    state _: inout FailureCleanupState,
  ) {}

  func executeToolCall(_: ToolCall, state _: FailureCleanupState) async throws -> String {
    ""
  }

  func appendText(_ text: String, to result: String) -> String {
    result + text
  }

  func toolDidExecute(
    _: ToolCall,
    result _: String,
    state _: inout FailureCleanupState,
  ) {}

  func toolDidFail(
    _: ToolCall,
    error _: any Error,
    state _: inout FailureCleanupState,
  ) {}

  func shouldCompact(state _: FailureCleanupState) -> Bool {
    false
  }

  func performCompaction(state: FailureCleanupState) async throws -> FailureCleanupState {
    state
  }

  func staleToolCallIDs(in _: FailureCleanupState) -> [String] {
    []
  }

  func recoverStaleToolCall(id _: String, state _: inout FailureCleanupState) {}

  func hasWork(state _: FailureCleanupState) -> Bool {
    false
  }

  func needsInference(state: FailureCleanupState) -> Bool {
    state.needsInference
  }
}
