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

  public var activity: SessionAgentActivity?
}

public struct SessionMetadata: Sendable, Equatable {
  public var model: String
  public var title: String
}

// MARK: - Action

public enum SessionAgentAction: Sendable {
  case inference(UUID, AutoRetryInference.Action)
  case interruptByUser(UserInitiation)
  case setMetadata(@Sendable (inout SessionMetadata) -> Void)
}

// MARK: - Interruption

public enum SessionAgentInterruption: Sendable {
  case byUser
}

// MARK: - Tool Result

public struct SessionAgentToolResult: Sendable {
}

// MARK: - Persistence Diff

public struct SessionAgentPersistenceDiff: Sendable {
}

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

  public func handle(_ action: Action, state: inout State) -> Interruption? {
    switch action {
    case .interruptByUser(var initiation):
      switch state.activity {
      case .inference(let inferenceState):
        if let partialMessage = inferenceState.partialMessage {
          state.transcript.items.append(SessionItem(id: inferenceState.inferenceID, content: .assistant(partialMessage)))
          // We need to order the messages.
          initiation.timestamp = date()
          state.transcript.items.append(SessionItem(id: UUID(), content: .interruption(.init(initiation: initiation))))

        }
        state.activity = nil

      default:
        fatalError("Unimplemented")
      }

      return .byUser

    case .setMetadata(let body):
      body(&state.metadata)

    case .inference(let inferenceID, let childAction):
      guard case .inference(var inferenceState) = state.activity,
            inferenceState.inferenceID == inferenceID
      else {
        print("[TO UPDATE LOG] fucked up state")
        return nil
      }

      switch childAction {
      case .inferenceStarted(let attempt):
        inferenceState.attempt = attempt
        inferenceState.attemptStartedAt = date()
        inferenceState.textDeltas = []
        state.activity = .inference(inferenceState)

      case let .textDelta(d, p):
        inferenceState.textDeltas.append(d)
        inferenceState.partialMessage = p
        state.activity = .inference(inferenceState)

      case .inferenceCompleted(let message):
        state.transcript.items.append(SessionItem(id: inferenceID, content: .assistant(message)))
        state.activity = nil
      }
    }

    return nil
  }

  public func nextToolCall(state: State) -> ToolCall? {
    state.transcript.pendingToolCalls.first
  }

  public func needsInference(state: State) -> Bool {
    state.transcript.needsInference
  }

  public func shouldCompact(state: State) -> Bool {
    false
  }

  public func drainToContext(state: inout State) {

  }

  public func buildContext(state: State) -> Context {
    Context(
      systemPrompt: "",
      messages: state.transcript.items.compactMap { $0.content.toWuhuAIMessage() },
      tools: [])
  }

  public func infer(context: Context, state: inout State) -> DeferredExecution<Action, Interruption> {
    let model = state.metadata.model

    precondition(state.activity == nil)
    let inferenceID = UUID()
    state.activity = .inference(.init(inferenceID: inferenceID))

    return inference.infer(
      model: model, context: context, options: .init(), interruption: Interruption.self
    ).map { childAction in
      Action.inference(inferenceID, childAction)
    }
  }

  public func startToolCall(_ call: ToolCall, state: inout State) -> DeferredExecution<Action, Interruption> {
    fatalError()
  }

  public func performCompaction(state: inout State) -> DeferredExecution<Action, Interruption> {
    fatalError()
  }

  public func persistAssistantEntry(_ message: AssistantMessage, state: inout State) {}
  public func persistToolResult(_ result: ToolResult, for call: ToolCall, state: inout State) {}

  public func diff(from oldState: State, to newState: State) -> PersistenceDiff? { nil }
  public func persist(_ diff: PersistenceDiff) async throws {}
}
