import Foundation
import PiAI

public struct SessionConfiguration: Sendable {
  public var model: Model
  public var systemPrompt: String
  public var virtualFileSystem: VirtualFileSystem

  public init(
    model: Model = .init(id: "claude-opus-4-6", provider: .anthropic),
    systemPrompt: String = "You are a helpful agent inside an agentic system that is under development. Your goal is to follow the user's instruction and do exactly as they say.",
    virtualFileSystem: VirtualFileSystem = .seededPlayground
  ) {
    self.model = model
    self.systemPrompt = systemPrompt
    self.virtualFileSystem = virtualFileSystem
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
  private var inferenceTask: Task<AssistantMessage, Error>?
  private var canDrainFollowUp = false
  private var joinWakeEvents: [JoinWakeEvent] = []
  private var pendingJoinToolCallID: String?
  private var activePersistentRuns: [String: ActivePersistentRun] = [:]

  public init(
    configuration: SessionConfiguration = .init(),
    environment: SessionEnvironment = .current()
  ) {
    self.configuration = configuration
    self.environment = environment
    self.tools = BuiltInTools.makeRegistry(
      virtualFileSystem: configuration.virtualFileSystem,
      sleepToolDriver: environment.sleepToolDriver
    )
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

  public func sendUserMessage(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if state.status == .paused {
      enqueueSteerMessage(trimmed)
      requestDrive()
      return
    }

    if isBusy {
      enqueueSteerMessage(trimmed)
      signalJoinWake(.steer(trimmed))
      requestDrive()
      return
    }

    appendUserMessage(trimmed)
    canDrainFollowUp = false
    requestDrive()
  }

  public func enqueueFollowUp(_ text: String) {
    enqueue(queue: &state.followUpQueue, text: text)
    publish()
  }

  public func enqueueNotification(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    enqueue(queue: &state.notificationQueue, text: trimmed)
    signalJoinWake(.notification(trimmed))
    publish()
    requestDrive()
  }

  public func stop() async {
    guard state.status != .paused else { return }

    state.status = .paused
    appendSystemMessage(kind: .control, text: "User stopped execution.")
    canDrainFollowUp = false

    inferenceTask?.cancel()
    inferenceTask = nil

    let runs = activePersistentRuns.values.map(\.session)
    activePersistentRuns.removeAll()
    state.activeToolCalls.removeAll()
    publish()

    for run in runs {
      await run.interrupt()
    }
  }

  public func resume() {
    guard state.status == .paused else { return }
    state.status = .idle
    publish()
    requestDrive()
  }

  private var isBusy: Bool {
    inferenceTask != nil || !activePersistentRuns.isEmpty || pendingJoinToolCallID != nil || isDriving
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

      if !activePersistentRuns.isEmpty || pendingJoinToolCallID != nil {
        state.status = .waitingForTools
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
      publish()

      do {
        try await performInferenceTurn()
        shouldDriveAgain = true
      } catch is CancellationError {
        if state.status != .paused {
          state.status = .idle
          publish()
        }
      } catch {
        state.lastError = error.localizedDescription
        state.status = .idle
        publish()
      }
    }
  }

  private var needsInference: Bool {
    guard let lastEntry = state.transcript.entries.last else { return false }

    switch lastEntry {
    case .userMessage, .toolResult, .systemMessage:
      return true
    case .assistantText, .toolCall:
      return false
    }
  }

  private func performInferenceTurn() async throws {
    let request = InferenceRequest(
      model: configuration.model,
      systemPrompt: configuration.systemPrompt,
      messages: state.transcript.contextMessages(model: configuration.model),
      tools: tools.exposedTools
    )

    let task = Task {
      try await environment.inferenceService.complete(request)
    }
    inferenceTask = task
    let assistantMessage = try await task.value
    inferenceTask = nil

    var emittedToolCalls = false

    for block in assistantMessage.content {
      switch block {
      case let .text(text):
        guard !text.text.isEmpty else { continue }
        state.transcript.append(
          .assistantText(
            .init(id: environment.uuid(), text: text.text, timestamp: assistantMessage.timestamp)
          )
        )

      case let .toolCall(call):
        emittedToolCalls = true
        state.transcript.append(
          .toolCall(
            .init(
              id: environment.uuid(),
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
    if call.name == "join" {
      try await startJoin(call, timestamp: timestamp)
      return
    }

    guard let registered = tools.lookup(call.name) else {
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

    switch registered {
    case let .nonPersistent(tool):
      do {
        let result = try await tool.execute(call)
        appendToolResult(toolCallID: call.id, toolName: call.name, result: result)
      } catch {
        appendToolResult(
          toolCallID: call.id,
          toolName: call.name,
          result: .init(content: [.text(error.localizedDescription)], isError: true)
        )
      }
      requestDrive()

    case let .persistent(tool):
      do {
        let session = try await tool.start(call)
        startPersistentRun(call: call, session: session, timestamp: timestamp)
      } catch {
        appendToolResult(
          toolCallID: call.id,
          toolName: call.name,
          result: .init(content: [.text(error.localizedDescription)], isError: true)
        )
        requestDrive()
      }
    }
  }

  private func startPersistentRun(call: ToolCall, session: PersistentToolSession, timestamp: Date) {
    state.activeToolCalls.append(
      .init(
        id: call.id,
        name: call.name,
        kind: .persistent,
        startedAt: timestamp,
        updatedAt: timestamp
      )
    )
    activePersistentRuns[call.id] = .init(name: call.name, session: session)
    publish()

    Task {
      for await event in session.events {
        await handlePersistentEvent(event, toolCallID: call.id, toolName: call.name)
      }
    }
  }

  private func handlePersistentEvent(_ event: PersistentToolEvent, toolCallID: String, toolName: String) async {
    guard activePersistentRuns[toolCallID] != nil else { return }

    switch event {
    case let .progress(message):
      updateToolRuntime(toolCallID: toolCallID, progressMessage: message)
      publish()

    case let .completed(result):
      activePersistentRuns.removeValue(forKey: toolCallID)
      removeActiveToolCall(toolCallID)
      appendToolResult(toolCallID: toolCallID, toolName: toolName, result: result)
      signalJoinWake(.toolCompleted(toolName: toolName, toolCallID: toolCallID))
      requestDrive()

    case let .failed(message):
      activePersistentRuns.removeValue(forKey: toolCallID)
      removeActiveToolCall(toolCallID)
      appendToolResult(
        toolCallID: toolCallID,
        toolName: toolName,
        result: .init(content: [.text(message)], isError: true)
      )
      signalJoinWake(.toolCompleted(toolName: toolName, toolCallID: toolCallID))
      requestDrive()
    }
  }

  private func startJoin(_ call: ToolCall, timestamp: Date) async throws {
    if let wakeEvent = joinWakeEvents.first {
      joinWakeEvents.removeFirst()
      appendToolResult(toolCallID: call.id, toolName: call.name, result: wakeEvent.result)
      requestDrive()
      return
    }

    pendingJoinToolCallID = call.id
    state.activeToolCalls.append(
      .init(
        id: call.id,
        name: call.name,
        kind: .join,
        startedAt: timestamp,
        updatedAt: timestamp
      )
    )
    publish()
  }

  private func signalJoinWake(_ wakeEvent: JoinWakeEvent) {
    joinWakeEvents.append(wakeEvent)

    guard let joinToolCallID = pendingJoinToolCallID else { return }
    pendingJoinToolCallID = nil
    removeActiveToolCall(joinToolCallID)

    if let nextWakeEvent = joinWakeEvents.first {
      joinWakeEvents.removeFirst()
      appendToolResult(toolCallID: joinToolCallID, toolName: "join", result: nextWakeEvent.result)
      requestDrive()
    }
  }

  private func drainSteerAndNotificationsIfNeeded() -> Bool {
    guard !state.steerQueue.isEmpty || !state.notificationQueue.isEmpty else { return false }

    for message in state.steerQueue {
      state.transcript.append(.userMessage(.init(id: environment.uuid(), text: message.text, timestamp: message.timestamp)))
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
      state.transcript.append(.userMessage(.init(id: environment.uuid(), text: message.text, timestamp: message.timestamp)))
    }
    state.followUpQueue.removeAll()
    canDrainFollowUp = false
    publish()
  }

  private func enqueueSteerMessage(_ text: String) {
    enqueue(queue: &state.steerQueue, text: text)
    publish()
  }

  private func appendUserMessage(_ text: String) {
    state.transcript.append(
      .userMessage(
        .init(id: environment.uuid(), text: text, timestamp: environment.now())
      )
    )
    publish()
  }

  private func appendSystemMessage(kind: SystemMessageKind, text: String) {
    state.transcript.append(
      .systemMessage(
        .init(id: environment.uuid(), kind: kind, text: text, timestamp: environment.now())
      )
    )
    publish()
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

  private func updateToolRuntime(toolCallID: String, progressMessage: String) {
    guard let index = state.activeToolCalls.firstIndex(where: { $0.id == toolCallID }) else { return }
    state.activeToolCalls[index].progress.append(progressMessage)
    state.activeToolCalls[index].updatedAt = environment.now()
  }

  private func removeActiveToolCall(_ toolCallID: String) {
    state.activeToolCalls.removeAll { $0.id == toolCallID }
    publish()
  }

  private func enqueue(queue: inout [QueuedMessage], text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.append(.init(id: environment.uuid(), text: trimmed, timestamp: environment.now()))
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

private struct ActivePersistentRun: Sendable {
  var name: String
  var session: PersistentToolSession
}

private enum JoinWakeEvent: Sendable, Hashable {
  case steer(String)
  case notification(String)
  case toolCompleted(toolName: String, toolCallID: String)

  var result: ToolCallResult {
    switch self {
    case let .steer(text):
      return .init(
        content: [.text("Woke because a steer message arrived.")],
        details: .object([
          "type": .string("steer"),
          "text": .string(text),
        ])
      )

    case let .notification(text):
      return .init(
        content: [.text("Woke because a notification arrived.")],
        details: .object([
          "type": .string("notification"),
          "text": .string(text),
        ])
      )

    case let .toolCompleted(toolName, toolCallID):
      return .init(
        content: [.text("Woke because \(toolName) finished.")],
        details: .object([
          "type": .string("toolCompleted"),
          "toolName": .string(toolName),
          "toolCallID": .string(toolCallID),
        ])
      )
    }
  }
}
