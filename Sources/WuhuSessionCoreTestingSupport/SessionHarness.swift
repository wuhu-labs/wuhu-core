import Foundation
import PiAI
import WuhuSessionCore

public struct ScriptedTurn: Sendable {
  public let id: UUID
  public var blocks: [ContentBlock]
  public var stopReason: StopReason
  public var streamedTextDeltas: [String]
  public var holdBeforeDone: Bool

  public init(
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

public actor InferenceHoldController {
  private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

  public init() {}

  public func holdStream(for id: UUID) -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuations[id] = continuation
    }
  }

  public func release(_ id: UUID) {
    continuations.removeValue(forKey: id)?.finish()
  }
}

public actor ScriptedInference {
  private var turns: [ScriptedTurn]
  private let holdController = InferenceHoldController()
  public private(set) var requests: [InferenceRequest] = []

  public init(turns: [ScriptedTurn]) {
    self.turns = turns
  }

  public func stream(_ request: InferenceRequest) throws -> AsyncThrowingStream<AssistantMessageEvent, any Error> {
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

  public func releaseTurn(id: UUID) async {
    await holdController.release(id)
  }
}

public actor ManualRuntimeToolController {
  private var continuations: [String: CheckedContinuation<ToolExecutionOutcome, Error>] = [:]

  public init() {}

  public func makeTool(named name: String = "wait") -> AnyToolExecutor {
    let tool = Tool(
      name: name,
      description: "Test-only controllable runtime tool.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ])
    )

    return AnyToolExecutor(tool: tool, lifecycle: .runtime(.process)) { call in
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolExecutionOutcome, Error>) in
          Task { await self.store(continuation, for: call.id) }
        }
      } onCancel: {
        Task { await self.cancel(toolCallID: call.id) }
      }
    }
  }

  public func complete(toolCallID: String, toolName: String = "wait", text: String = "Completed runtime tool.") {
    continuations.removeValue(forKey: toolCallID)?.resume(
      returning: .init(
        result: .init(
          content: [.text(text)],
          details: .object([
            "toolCallID": .string(toolCallID),
            "toolName": .string(toolName),
          ])
        )
      )
    )
  }

  public func fail(toolCallID: String, message: String) {
    continuations.removeValue(forKey: toolCallID)?.resume(
      returning: .init(
        result: .init(
          content: [.text(message)],
          isError: true
        )
      )
    )
  }

  private func store(_ continuation: CheckedContinuation<ToolExecutionOutcome, Error>, for toolCallID: String) {
    continuations[toolCallID] = continuation
  }

  private func cancel(toolCallID: String) {
    continuations.removeValue(forKey: toolCallID)?.resume(throwing: CancellationError())
  }
}

public actor StateTracker<Value: Sendable> {
  private struct Waiter {
    var predicate: @Sendable (Value) -> Bool
    var continuation: CheckedContinuation<Value, Never>
  }

  private var latest: Value
  private var waiters: [Waiter] = []
  private var task: Task<Void, Never>?

  public init(initial: Value) {
    self.latest = initial
  }

  public func start(stream: AsyncStream<Value>) {
    task = Task {
      for await value in stream {
        self.receive(value)
      }
    }
  }

  public func current() -> Value {
    latest
  }

  public func waitUntil(_ predicate: @escaping @Sendable (Value) -> Bool) async -> Value {
    if predicate(latest) {
      return latest
    }

    return await withCheckedContinuation { continuation in
      waiters.append(.init(predicate: predicate, continuation: continuation))
    }
  }

  public func finish() {
    task?.cancel()
    task = nil
  }

  private func receive(_ value: Value) {
    latest = value

    var remaining: [Waiter] = []
    for waiter in waiters {
      if waiter.predicate(value) {
        waiter.continuation.resume(returning: value)
      } else {
        remaining.append(waiter)
      }
    }
    waiters = remaining
  }
}

public struct SessionHarness {
  public let session: SessionActor
  public let inference: ScriptedInference
  public let tracker: StateTracker<AgentState>

  public init(
    turns: [ScriptedTurn],
    tools: ToolRegistry = .init(exposedTools: [], executors: [:]),
    configuration: SessionConfiguration = .init()
  ) async {
    let inference = ScriptedInference(turns: turns)
    let environment = SessionEnvironment(
      inferenceService: .init(stream: { request in
        try await inference.stream(request)
      }),
      now: Date.init,
      uuid: UUID.init
    )

    let session = SessionActor(
      configuration: configuration,
      environment: environment,
      tools: tools
    )

    let tracker = StateTracker<AgentState>(initial: .init())
    await tracker.start(stream: await session.subscribe())

    self.session = session
    self.inference = inference
    self.tracker = tracker
  }

  public func enqueueSteer(_ text: String) async {
    await session.enqueueUserMessage(text, lane: .steer)
  }

  public func enqueueFollowUp(_ text: String) async {
    await session.enqueueUserMessage(text, lane: .followUp)
  }

  public func enqueueNotification(_ text: String) async {
    await session.enqueueNotification(text)
  }

  public func stop() async {
    await session.stop()
  }

  public func resume() async {
    await session.resume()
  }

  public func releaseTurn(_ turn: ScriptedTurn) async {
    await inference.releaseTurn(id: turn.id)
  }

  public func waitUntilIdle(minimumTranscriptEntries: Int = 1) async -> AgentState {
    await tracker.waitUntil { state in
      state.status == .idle
        && state.activeToolCalls.isEmpty
        && state.assistantDraft == nil
        && state.transcript.entries.count >= minimumTranscriptEntries
    }
  }

  public func waitUntilWaitingForTools(minimumTranscriptEntries: Int = 1) async -> AgentState {
    await tracker.waitUntil { state in
      state.status == .waitingForTools
        && !state.activeToolCalls.isEmpty
        && state.transcript.entries.count >= minimumTranscriptEntries
    }
  }

  public func waitUntilPaused() async -> AgentState {
    await tracker.waitUntil { $0.status == .paused }
  }

  public func waitUntilDraftText(_ text: String) async -> AgentState {
    await tracker.waitUntil { $0.assistantDraft?.text == text }
  }

  public func finish() async {
    await tracker.finish()
  }
}

public extension Transcript {
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
      case let .semantic(record):
        return "semantic: \(record.entry.typeDescription)"
      case let .systemMessage(message):
        return "system[\(message.kind.rawValue)]: \(message.text)"
      }
    }
  }
}

public func toolCall(_ id: String, _ name: String, args: JSONValue = .object([:])) -> ContentBlock {
  .toolCall(.init(id: id, name: name, arguments: args))
}
