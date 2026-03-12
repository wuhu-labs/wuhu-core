import Foundation
import Testing
@testable import WuhuSessionCore

struct ScriptedTurn: Sendable {
  let id: UUID
  var blocks: [ContentBlock]
  var stopReason: StopReason
  var streamedTextDeltas: [String]
  var holdBeforeDone: Bool

  init(
    blocks: [ContentBlock],
    stopReason: StopReason = .stop,
    streamedTextDeltas: [String] = [],
    holdBeforeDone: Bool = false
  ) {
    self.id = UUID()
    self.blocks = blocks
    self.stopReason = stopReason
    self.streamedTextDeltas = streamedTextDeltas
    self.holdBeforeDone = holdBeforeDone
  }
}

actor InferenceHoldController {
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  func holdStream(for id: UUID) -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuations[id] = continuation
    }
  }

  func release(_ id: UUID) {
    continuations.removeValue(forKey: id)?.finish()
  }
}

actor ScriptedInference {
  private var turns: [ScriptedTurn]
  private let holdController = InferenceHoldController()
  private(set) var requests: [InferenceRequest] = []

  init(turns: [ScriptedTurn]) {
    self.turns = turns
  }

  func stream(_ request: InferenceRequest) throws -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
    requests.append(request)
    guard !turns.isEmpty else {
      throw ToolError.message("No scripted inference turn remains.")
    }

    let turn = turns.removeFirst()
    return AsyncThrowingStream { continuation in
      let provider = request.model.provider
      let model = request.model.id
      let timestamp = Date()

      Task {
        if !turn.streamedTextDeltas.isEmpty {
          var partialText = ""
          continuation.yield(
            .start(
              partial: AssistantMessage(
                provider: provider,
                model: model,
                content: [],
                stopReason: turn.stopReason,
                timestamp: timestamp
              )
            )
          )

          for delta in turn.streamedTextDeltas {
            partialText += delta
            continuation.yield(
              .textDelta(
                delta: delta,
                partial: AssistantMessage(
                  provider: provider,
                  model: model,
                  content: partialText.isEmpty ? [] : [.text(partialText)],
                  stopReason: turn.stopReason,
                  timestamp: timestamp
                )
              )
            )
            await Task.yield()
          }
        }

        if turn.holdBeforeDone {
          let holdStream = await self.holdController.holdStream(for: turn.id)
          for await _ in holdStream {
            break
          }
        }

        await Task.yield()
        continuation.yield(
          .done(
            message: AssistantMessage(
              provider: provider,
              model: model,
              content: turn.blocks,
              stopReason: turn.stopReason,
              timestamp: timestamp
            )
          )
        )
        continuation.finish()
      }
    }
  }

  func releaseTurn(id: UUID) async {
    await holdController.release(id)
  }
}

actor ManualSleepDriver {
  struct Run {
    var minutes: Int
    var elapsed: Int
    var continuation: AsyncStream<PersistentToolEvent>.Continuation
  }

  private var runs: [String: Run] = [:]

  func start(toolCallID: String, minutes: Int) -> PersistentToolSession {
    let events = AsyncStream<PersistentToolEvent> { continuation in
      self.runs[toolCallID] = Run(minutes: minutes, elapsed: 0, continuation: continuation)
    }

    return PersistentToolSession(
      events: events,
      interrupt: {
        await self.interrupt(toolCallID: toolCallID)
      }
    )
  }

  func advance(toolCallID: String, by minutes: Int = 1) {
    guard var run = runs[toolCallID] else { return }

    for _ in 0 ..< minutes {
      run.elapsed += 1
      if run.elapsed < run.minutes {
        run.continuation.yield(.progress("\(run.elapsed) minute has passed"))
      } else {
        run.continuation.yield(.progress("\(run.elapsed) minute has passed"))
        run.continuation.yield(
          .completed(
            ToolCallResult(
              content: [.text("Completed \(run.minutes) minute sleep.")],
              details: .object([
                "toolCallID": .string(toolCallID),
                "minutes": .number(Double(run.minutes)),
              ])
            )
          )
        )
        run.continuation.finish()
        runs.removeValue(forKey: toolCallID)
        return
      }
    }

    runs[toolCallID] = run
  }

  func interrupt(toolCallID: String) {
    guard let run = runs.removeValue(forKey: toolCallID) else { return }
    run.continuation.finish()
  }
}

actor StateTracker {
  private struct Waiter {
    var predicate: @Sendable (AgentState) -> Bool
    var continuation: CheckedContinuation<AgentState, Never>
  }

  private var latest: AgentState = .init()
  private var waiters: [Waiter] = []

  init(stream: AsyncStream<AgentState>) {
    Task {
      for await state in stream {
        await self.receive(state)
      }
    }
  }

  func current() -> AgentState {
    latest
  }

  func waitUntil(_ predicate: @escaping @Sendable (AgentState) -> Bool) async -> AgentState {
    if predicate(latest) {
      return latest
    }

    return await withCheckedContinuation { continuation in
      waiters.append(.init(predicate: predicate, continuation: continuation))
    }
  }

  private func receive(_ state: AgentState) {
    latest = state

    var remaining: [Waiter] = []
    for waiter in waiters {
      if waiter.predicate(state) {
        waiter.continuation.resume(returning: state)
      } else {
        remaining.append(waiter)
      }
    }
    waiters = remaining
  }
}

struct SessionHarness {
  let session: SessionActor
  let inference: ScriptedInference
  let sleep: ManualSleepDriver
  let tracker: StateTracker
  let turns: [ScriptedTurn]

  init(
    turns: [ScriptedTurn],
    virtualFileSystem: VirtualFileSystem = .seededPlayground
  ) async {
    let inference = ScriptedInference(turns: turns)
    let sleep = ManualSleepDriver()
    let environment = SessionEnvironment(
      inferenceService: .init(stream: { request in
        try await inference.stream(request)
      }),
      sleepToolDriver: .init { toolCallID, minutes in
        await sleep.start(toolCallID: toolCallID, minutes: minutes)
      },
      now: Date.init,
      uuid: UUID.init
    )

    let session = SessionActor(
      configuration: .init(virtualFileSystem: virtualFileSystem),
      environment: environment
    )

    let tracker = StateTracker(stream: await session.subscribe())

    self.session = session
    self.inference = inference
    self.sleep = sleep
    self.tracker = tracker
    self.turns = turns
  }

  func enqueueSteer(_ text: String) async {
    await session.enqueueUserMessage(text, lane: .steer)
  }

  func enqueueFollowUp(_ text: String) async {
    await session.enqueueUserMessage(text, lane: .followUp)
  }

  func enqueueNotification(_ text: String) async {
    await session.enqueueNotification(text)
  }

  func stop() async {
    await session.stop()
  }

  func resume() async {
    await session.resume()
  }

  func advanceSleep(toolCallID: String, by minutes: Int = 1) async {
    await sleep.advance(toolCallID: toolCallID, by: minutes)
  }

  func releaseTurn(_ turn: ScriptedTurn) async {
    await inference.releaseTurn(id: turn.id)
  }

  func waitUntilIdle(minimumTranscriptEntries: Int = 1) async -> AgentState {
    await tracker.waitUntil { state in
      state.status == .idle
        && state.activeToolCalls.isEmpty
        && state.assistantDraft == nil
        && state.transcript.entries.count >= minimumTranscriptEntries
    }
  }

  func waitUntilWaitingForTools(minimumTranscriptEntries: Int = 1) async -> AgentState {
    await tracker.waitUntil { state in
      state.status == .waitingForTools
        && !state.activeToolCalls.isEmpty
        && state.transcript.entries.count >= minimumTranscriptEntries
    }
  }

  func waitUntilPaused() async -> AgentState {
    await tracker.waitUntil { $0.status == .paused }
  }

  func waitUntilDraftText(_ text: String) async -> AgentState {
    await tracker.waitUntil { $0.assistantDraft?.text == text }
  }
}

extension Transcript {
  var debugSummary: [String] {
    entries.map { entry in
      switch entry {
      case let .userMessage(message):
        return "user[\(message.lane.rawValue)]: \(message.text)"
      case let .assistantText(message):
        return "assistant[\(message.completion.rawValue)]: \(message.text)"
      case let .toolCall(call):
        return "tool-call[\(call.toolCallID)]: \(call.toolName)"
      case let .toolResult(result):
        let text = result.content.compactMap { block -> String? in
          if case let .text(text) = block {
            return text.text
          }
          return nil
        }.joined(separator: "\n")
        return "tool-result[\(result.toolCallID)]: \(result.toolName) -> \(text)"
      case let .systemMessage(message):
        return "system[\(message.kind.rawValue)]: \(message.text)"
      }
    }
  }
}

func toolCall(_ id: String, _ name: String, args: JSONValue = .object([:])) -> ContentBlock {
  .toolCall(.init(id: id, name: name, arguments: args))
}
