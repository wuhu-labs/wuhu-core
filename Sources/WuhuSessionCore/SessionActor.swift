import Foundation
import PiAI

public struct SessionConfiguration: Sendable {
  public var model: Model
  public var systemPrompt: String

  public init(
    model: Model = .init(id: "claude-opus-4-6", provider: .anthropic),
    systemPrompt: String = "You are a helpful agent inside an agentic system that is under development. Your goal is to follow the user's instruction and do exactly as they say."
  ) {
    self.model = model
    self.systemPrompt = systemPrompt
  }
}

public actor SessionActor {
  private var state: AgentState
  private let configuration: SessionConfiguration
  private let environment: SessionEnvironment
  private let tools: ToolRegistry

  private var subscriberContinuations: [UUID: AsyncStream<AgentState>.Continuation] = [:]
  private var shouldDriveAgain = false
  private var isDriving = false
  private var inferenceTask: Task<Void, Error>?
  private var canDrainFollowUp = false

  public init(
    configuration: SessionConfiguration = .init(),
    environment: SessionEnvironment = .current(),
    tools: ToolRegistry = .init(exposedTools: [], executors: [:])
  ) {
    self.configuration = configuration
    self.environment = environment
    self.tools = tools
    self.state = AgentState()
  }

  public func snapshot() -> AgentState {
    state
  }

  public func subscribe() -> AsyncStream<AgentState> {
    let id = environment.uuid()
    return AsyncStream { continuation in
      continuation.yield(self.state)
      self.subscriberContinuations[id] = continuation
      continuation.onTermination = { _ in
        Task { await self.removeSubscriber(id: id) }
      }
    }
  }

  public func enqueueUserMessage(_ text: String, lane: UserMessageLane, preserveThinking: Bool = false) {
    switch lane {
    case .steer:
      enqueueSteerMessage(text, preserveThinking: preserveThinking)
      requestDrive()
    case .followUp:
      enqueueFollowUp(text, preserveThinking: preserveThinking)
    }
  }

  public func enqueueFollowUp(_ text: String, preserveThinking: Bool = false) {
    enqueue(queue: &state.followUpQueue, text: text, preserveThinking: preserveThinking)
    publish()
    requestDrive()
  }

  public func enqueueNotification(_ text: String) {
    enqueue(queue: &state.notificationQueue, text: text)
    publish()
    requestDrive()
  }

  public func stop() async {
    guard state.status != .paused else { return }

    state.status = .paused
    inferenceTask?.cancel()
    inferenceTask = nil
    state.activeToolCalls.removeAll()
    commitDraftIfNeeded(as: .interrupted)
    appendSystemMessage(kind: .control, text: "User stopped execution.")
    canDrainFollowUp = false
    publish()
  }

  public func resume() {
    guard state.status == .paused else { return }
    state.status = .idle
    publish()
    requestDrive()
  }

  private func requestDrive() {
    shouldDriveAgain = true
    guard !isDriving else { return }

    Task {
      await self.driveLoop()
    }
  }

  private func driveLoop() async {
    guard !isDriving else { return }
    isDriving = true

    defer {
      isDriving = false
      if shouldDriveAgain {
        Task { await self.driveLoop() }
      }
    }

    while shouldDriveAgain {
      shouldDriveAgain = false

      if state.status == .paused {
        publish()
        continue
      }

      if drainSteerAndNotificationsIfNeeded() {
        shouldDriveAgain = true
        continue
      }

      if canDrainFollowUp, !state.followUpQueue.isEmpty {
        drainFollowUp()
        shouldDriveAgain = true
        continue
      }

      if !needsInference {
        state.status = .idle
        publish()
        continue
      }

      state.status = .running
      state.lastError = nil
      publish()

      do {
        try await performInferenceTurn()
        shouldDriveAgain = true
      } catch is CancellationError {
        state.assistantDraft = nil
        state.activeToolCalls.removeAll()
        if state.status != .paused {
          state.status = .idle
          publish()
        }
      } catch {
        inferenceTask = nil
        state.assistantDraft = nil
        state.activeToolCalls.removeAll()
        state.lastError = error.localizedDescription
        state.status = .idle
        publish()
      }
    }
  }

  private var needsInference: Bool {
    guard
      let lastEntry = state.transcript.entries.last(where: { entry in
        if case .semantic = entry {
          return false
        }
        return true
      })
    else {
      return false
    }

    switch lastEntry {
      case .userMessage, .toolResult, .systemMessage:
      return true
    case .assistantText, .toolCall:
      return false
    case .semantic:
      return false
    }
  }

  private func performInferenceTurn() async throws {
    let responseID = environment.uuid()
    let request = InferenceRequest(
      model: configuration.model,
      systemPrompt: configuration.systemPrompt,
      messages: state.transcript.contextMessages(model: configuration.model),
      tools: tools.exposedTools
    )

    let task = Task { [environment] in
      let stream = try await environment.inferenceService.stream(request)
      for try await event in stream {
        try Task.checkCancellation()
        try await self.receiveInferenceEvent(event, responseID: responseID)
      }
    }

    inferenceTask = task
    let now = environment.now()
    state.assistantDraft = .init(
      responseID: responseID,
      startedAt: now,
      updatedAt: now
    )
    publish()

    do {
      try await task.value
      inferenceTask = nil
    } catch {
      inferenceTask = nil
      throw error
    }
  }

  private func receiveInferenceEvent(_ event: AssistantMessageEvent, responseID: UUID) async throws {
    switch event {
    case let .start(partial):
      updateAssistantDraft(responseID: responseID, text: assistantDraftText(from: partial))

    case let .textDelta(_, partial):
      updateAssistantDraft(responseID: responseID, text: assistantDraftText(from: partial))

    case let .done(message):
      state.assistantDraft = nil
      try await commitAssistantMessage(message, responseID: responseID)
    }
  }

  private func commitAssistantMessage(_ assistantMessage: AssistantMessage, responseID: UUID) async throws {
    var emittedToolCalls = false

    for block in assistantMessage.content {
      switch block {
      case let .text(text):
        guard !text.text.isEmpty else { continue }
        appendAssistantText(
          responseID: responseID,
          text: text.text,
          completion: .finished,
          timestamp: assistantMessage.timestamp
        )

      case let .toolCall(call):
        emittedToolCalls = true
        state.transcript.append(
          .toolCall(
            .init(
              id: environment.uuid(),
              responseID: responseID,
              toolCallID: call.id,
              toolName: call.name,
              arguments: call.arguments,
              timestamp: assistantMessage.timestamp
            )
          )
        )
        try await executeToolCall(call, timestamp: assistantMessage.timestamp)

      case .reasoning, .image:
        continue
      }
    }

    canDrainFollowUp = !emittedToolCalls
    publish()
  }

  private func executeToolCall(_ call: ToolCall, timestamp: Date) async throws {
    guard let executor = tools.lookup(call.name) else {
      appendToolResult(
        toolCallID: call.id,
        toolName: call.name,
        result: .init(
          content: [.text("Unknown tool: \(call.name)")],
          isError: true
        )
      )
      requestDrive()
      return
    }

    let isRuntimeTool: Bool
    switch executor.lifecycle {
    case .immediate:
      isRuntimeTool = false
    case let .runtime(kind):
      isRuntimeTool = true
      state.activeToolCalls.append(
        .init(
          id: call.id,
          name: call.name,
          kind: kind,
          startedAt: timestamp,
          updatedAt: timestamp
        )
      )
      state.status = .waitingForTools
      publish()
    }

    do {
      let outcome = try await executor.execute(call)
      if isRuntimeTool {
        removeActiveToolCall(call.id, publishAfterRemoval: false)
      }
      appendToolResult(toolCallID: call.id, toolName: call.name, result: outcome.result)
      appendSemanticEntries(outcome.semanticEntries)
      requestDrive()
    } catch is CancellationError {
      if isRuntimeTool {
        removeActiveToolCall(call.id)
      }
      throw CancellationError()
    } catch {
      if isRuntimeTool {
        removeActiveToolCall(call.id, publishAfterRemoval: false)
      }
      appendToolResult(
        toolCallID: call.id,
        toolName: call.name,
        result: .init(content: [.text(error.localizedDescription)], isError: true)
      )
      requestDrive()
    }
  }

  private func drainSteerAndNotificationsIfNeeded() -> Bool {
    guard !state.steerQueue.isEmpty || !state.notificationQueue.isEmpty else { return false }

    for message in state.steerQueue {
      appendUserMessage(
        text: message.text,
        lane: .steer,
        preserveThinking: message.preserveThinking,
        timestamp: message.timestamp
      )
    }

    for message in state.notificationQueue {
      state.transcript.append(
        .systemMessage(
          .init(id: environment.uuid(), kind: .notification, text: message.text, timestamp: message.timestamp)
        )
      )
    }

    state.steerQueue.removeAll()
    state.notificationQueue.removeAll()
    canDrainFollowUp = false
    publish()
    return true
  }

  private func drainFollowUp() {
    for message in state.followUpQueue {
      appendUserMessage(
        text: message.text,
        lane: .followUp,
        preserveThinking: message.preserveThinking,
        timestamp: message.timestamp
      )
    }
    state.followUpQueue.removeAll()
    canDrainFollowUp = false
    publish()
  }

  private func enqueueSteerMessage(_ text: String, preserveThinking: Bool = false) {
    enqueue(queue: &state.steerQueue, text: text, preserveThinking: preserveThinking)
    publish()
  }

  private func appendUserMessage(
    text: String,
    lane: UserMessageLane,
    preserveThinking: Bool,
    timestamp: Date
  ) {
    state.transcript.append(
      .userMessage(
        .init(
          id: environment.uuid(),
          text: text,
          lane: lane,
          preserveThinking: preserveThinking,
          timestamp: timestamp
        )
      )
    )
  }

  private func appendSystemMessage(kind: SystemMessageKind, text: String) {
    state.transcript.append(
      .systemMessage(
        .init(id: environment.uuid(), kind: kind, text: text, timestamp: environment.now())
      )
    )
  }

  private func appendToolResult(toolCallID: String, toolName: String, result: ToolCallResult) {
    state.transcript.append(
      .toolResult(
        .init(
          id: environment.uuid(),
          toolCallID: toolCallID,
          toolName: toolName,
          content: result.content,
          details: result.details,
          isError: result.isError,
          timestamp: environment.now()
        )
      )
    )
    publish()
  }

  private func appendSemanticEntries(_ entries: [AnySemanticEntry]) {
    guard !entries.isEmpty else { return }
    let now = environment.now()
    for entry in entries {
      state.transcript.append(
        .semantic(
          .init(
            id: environment.uuid(),
            entry: entry,
            timestamp: now
          )
        )
      )
    }
    publish()
  }

  private func updateAssistantDraft(responseID: UUID, text: String) {
    let now = environment.now()
    if var draft = state.assistantDraft, draft.responseID == responseID {
      draft.text = text
      draft.updatedAt = now
      state.assistantDraft = draft
    } else {
      state.assistantDraft = .init(responseID: responseID, text: text, startedAt: now, updatedAt: now)
    }
    publish()
  }

  private func assistantDraftText(from message: AssistantMessage) -> String {
    message.content.compactMap { block -> String? in
      if case let .text(text) = block {
        return text.text
      }
      return nil
    }.joined()
  }

  private func removeActiveToolCall(_ toolCallID: String, publishAfterRemoval: Bool = true) {
    state.activeToolCalls.removeAll { $0.id == toolCallID }
    if publishAfterRemoval {
      publish()
    }
  }

  private func commitDraftIfNeeded(as completion: AssistantCompletionState) {
    guard let draft = state.assistantDraft else { return }
    state.assistantDraft = nil
    guard !draft.text.isEmpty else { return }

    appendAssistantText(
      responseID: draft.responseID,
      text: draft.text,
      completion: completion,
      timestamp: draft.updatedAt
    )
  }

  private func appendAssistantText(
    responseID: UUID,
    text: String,
    completion: AssistantCompletionState,
    timestamp: Date
  ) {
    state.transcript.append(
      .assistantText(
        .init(
          id: environment.uuid(),
          responseID: responseID,
          text: text,
          completion: completion,
          timestamp: timestamp
        )
      )
    )
  }

  private func enqueue(queue: inout [QueuedMessage], text: String, preserveThinking: Bool = false) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.append(.init(id: environment.uuid(), text: trimmed, preserveThinking: preserveThinking, timestamp: environment.now()))
  }

  private func publish() {
    let snapshot = state
    for continuation in subscriberContinuations.values {
      continuation.yield(snapshot)
    }
  }

  private func removeSubscriber(id: UUID) {
    subscriberContinuations.removeValue(forKey: id)
  }
}
