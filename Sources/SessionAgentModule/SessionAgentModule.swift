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

  public var foundationTools: FoundationTool.State

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
  case setMetadata(@Sendable (inout SessionMetadata) -> Void)
  case user(SessionAgentUserAction)

  case inference(UUID, AutoRetryInference.Action)
  case foundationTool(FoundationTool.Action)
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
  public let foundationTool = FoundationTool()

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

    case let .foundationTool(childAction):
      switch childAction {
      case let .toolCallDidFinish(result):
        let message = ToolResultMessage(
          toolCallId: result.toolCallId,
          toolName: result.toolName,
          content: result.toContentBlock(),
          isError: result.isError,
          timestamp: result.timestamp,
        )
        state.transcript.items.append(.init(id: UUID(), content: .toolResult(message)))
      default:
        break
      }
      foundationTool.reduce(action: childAction, state: &state.foundationTools)
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

  public func startToolCall(_ toolCall: ToolCall, state: inout State) -> DeferredExecution<Action> {
    foundationTool.startToolCall(toolCall, state: &state.foundationTools)
      .map(Action.foundationTool)
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
