import AgentLoopModule
import Dependencies
import Foundation
import WuhuAI

// MARK: - State

public enum SessionAgentActivity: Equatable, Sendable {
  case inference(InferenceActivity)

  public struct InferenceActivity: Equatable, Sendable {
    public var inferenceID: UUID
    public var attempt: Int = 0
    public var attemptStartedAt: Date = .distantPast
    public var textDeltas: [String] = []
    public var partialMessage: AssistantMessage?
  }
}

public struct SessionAgentState: Sendable, Equatable {
  public var metadata: SessionMetadata
  public var transcript: SessionTranscript

  public var steerQueue: SessionQueue<UserQueueItemValue>
  public var followUpQueue: SessionQueue<UserQueueItemValue>

  public subscript(userQueue lane: UserQueueLane) -> SessionQueue<UserQueueItemValue> {
    get {
      switch lane {
      case .steer:
        steerQueue
      case .followUp:
        followUpQueue
      }
    }
    set {
      switch lane {
      case .steer:
        steerQueue = newValue
      case .followUp:
        followUpQueue = newValue
      }
    }
  }

  public var activity: SessionAgentActivity?
}

public struct SessionMetadata: Sendable, Equatable {
  public var model: String
  public var title: String
}

// MARK: - Action

public enum SessionAgentAction: Sendable {
  case inference(UUID, AutoRetryInference.Action)
  case setMetadata(@Sendable (inout SessionMetadata) -> Void)
  case user(SessionAgentUserAction)
  case mount(SessionMountMessage)
}

public struct SessionAgentUserAction: Sendable {
  public var initiation: UserInitiation
  public var action: Action

  public enum Action: Sendable {
    case interrupt
    case enqueue(UserQueueLane, [ContentBlock])
    case dequeue(UserQueueLane, UUID)
  }
}

// MARK: - Interruption

public enum SessionAgentInterruption: Sendable {
  case byUser(UserInitiation)
}

// MARK: - Tool Result

public struct SessionAgentToolResult: Sendable {}

// MARK: - Persistence Diff

public struct SessionAgentPersistenceDiff: Sendable {}

// MARK: - Behavior

public struct SessionAgentBehavior: AgentBehavior {
  @Dependency(\.date)
  private var date

  public let inference = AutoRetryInference()

  public typealias State = SessionAgentState
  public typealias Action = SessionAgentAction
  public typealias Interruption = SessionAgentInterruption
  public typealias ToolResult = SessionAgentToolResult
  public typealias PersistenceDiff = SessionAgentPersistenceDiff

  public func handle(_ action: Action, state: inout State) {
    let now = date()

    switch action {
    case let .user(userAction):
      var initiation = userAction.initiation
      // We need to order the messages.
      initiation.timestamp = now

      switch userAction.action {
      case .interrupt:
        switch state.activity {
        case let .inference(inferenceState):
          if let partialMessage = inferenceState.partialMessage {
            state.transcript.items.append(SessionItem(id: inferenceState.inferenceID, content: .assistant(partialMessage)))
            state.transcript.items.append(SessionItem(id: UUID(), content: .interruption(.init(initiation: initiation))))
          }
          state.activity = nil

        default:
          fatalError("Unimplemented")
        }
        return

      case let .enqueue(lane, content):
        state[userQueue: lane].append(.init(id: UUID(), value: .init(initiation: initiation, content: content)))

      case let .dequeue(lane, itemID):
        state[userQueue: lane].remove(itemWithID: itemID)
      }

    case let .setMetadata(body):
      body(&state.metadata)

    case let .inference(inferenceID, childAction):
      guard case var .inference(inferenceState) = state.activity,
            inferenceState.inferenceID == inferenceID
      else {
        print("[TO UPDATE LOG] fucked up state")
        return
      }

      switch childAction {
      case let .inferenceStarted(attempt):
        inferenceState.attempt = attempt
        inferenceState.attemptStartedAt = date()
        inferenceState.textDeltas = []
        state.activity = .inference(inferenceState)

      case let .textDelta(d, p):
        inferenceState.textDeltas.append(d)
        inferenceState.partialMessage = p
        state.activity = .inference(inferenceState)

      case let .inferenceCompleted(message):
        state.transcript.items.append(SessionItem(id: inferenceID, content: .assistant(message)))
        state.activity = nil
      }

    case let .mount(message):
      state.transcript.items.append(SessionItem(id: UUID(), content: .mount(message)))
    }
  }

  public func nextToolCall(state: State) -> ToolCall? {
    state.transcript.pendingToolCalls.first
  }

  public func nextContextAction(state: SessionAgentState) -> AgentContextAction? {
    if state.transcript.needsInference {
      .inference
    } else if state.steerQueue.isEmpty, state.followUpQueue.isEmpty {
      nil
    } else {
      .drain
    }
  }

  public func shouldCompact(state _: State) -> Bool {
    false
  }

  public func drainToContext(state: inout State) {
    // TODO: we should drain from both system and user and mark if we have more to go. capped at 20 and order by time. we probably want a single pending messages struct
    let queueItems = if !state.steerQueue.isEmpty {
      state.steerQueue.pop(max: 20)
    } else {
      state.followUpQueue.pop(max: 1)
    }

    for item in queueItems {
      let content = SessionUserMessage(initiation: item.value.initiation, content: item.value.content)
      state.transcript.items.append(.init(id: item.id, content: .user(content)))
    }
  }

  public func buildContext(state: State) -> Context {
    Context(
      systemPrompt: "",
      messages: state.transcript.items.compactMap { $0.content.toWuhuAIMessage() },
      tools: [],
    )
  }

  public func infer(context: Context, state: inout State) -> DeferredExecution<Action> {
    let model = state.metadata.model

    precondition(state.activity == nil)
    let inferenceID = UUID()
    state.activity = .inference(.init(inferenceID: inferenceID))

    return inference.infer(
      model: model, context: context, options: .init(), interruption: Interruption.self,
    ).map { childAction in
      Action.inference(inferenceID, childAction)
    }
  }

  public func startToolCall(_ untypedToolCall: ToolCall, state: inout State) -> DeferredExecution<Action> {
    let toolCall: SessionToolCall

    func appendToolError(error: String) {
      let toolResult = ToolResultMessage(
        toolCallId: untypedToolCall.id,
        toolName: untypedToolCall.name,
        content: [.text(error)],
        isError: true,
        timestamp: date(),
      )
      state.transcript.items.append(.init(id: UUID(), content: .toolResult(toolResult)))
    }

    do {
      toolCall = try SessionToolCall.parse(untypedToolCall)
    } catch {
      appendToolError(error: "Failed to parse tool call: \(String(describing: error))")
      return .none
    }

    switch toolCall {
    case let .read(readToolCall):
      fatalError()

    case let .write(writeToolCall):
      fatalError()

    case let .find(findToolCall):
      fatalError()

    case let .bash(bashToolCall):
      fatalError()

    case let .setTitle(tc):
      state.metadata.title = tc.title
      return .none

    case let .mount(mount):
    }

    /*
     * let's classify tool kinds
     *
     * - simple sync state update
     * - simple async idempotent
     * - simple async mutating
     * - simple async mutating + long term
     * - join
     */

//    if call.name == "set_title" {
//      if case .object(let dict) = call.arguments,
//         let titleUntyped = dict["title"],
//         case .string(let title) = titleUntyped
//      {
//
//        state.metadata.title = title
//        return .init { _ in }
//      }
//
//    }

    fatalError()

//
//      if call.name == "bash" {
//        return startBashToolCall(call, state: &state)
//      }
//
//      if state.toolCallStatus[call.id] == .started {
//        let repairedResult = staleToolCallResult(call: call)
//        return .init { repairedResult }
//      }
//
//      state.toolCallStatus[call.id] = .started
//      state.status = .init(status: .running)
//
//      let executionState = state
//      return .init { [self] in
//        do {
//          let tools = await tools(for: executionState)
//          guard let tool = tools.first(where: { $0.tool.name == call.name }) else {
//            return makeToolErrorResult(call: call, errorDescription: "Unknown tool: \(call.name)")
//          }
//          return try await tool.execute(toolCallId: call.id, args: call.arguments)
//        } catch {
//          return makeToolErrorResult(call: call, errorDescription: "\(error)")
//        }
//      }
  }

  public func performCompaction(state _: inout State) -> DeferredExecution<Action> {
    fatalError()
  }

  public func diff(from _: State, to _: State) -> PersistenceDiff? {
    fatalError()
  }

  public func persist(_: PersistenceDiff) async throws {
    fatalError()
  }
}
