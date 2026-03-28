import AgentLoopModule
import Dependencies
import Foundation
import WuhuAI

// MARK: - State


public struct SessionAgentState: Sendable, Equatable {
  public var metadata: SessionMetadata
  public var transcript: SessionTranscript
}

public struct SessionMetadata: Sendable, Equatable {
  public var model: String
  public var title: String
}

// MARK: - Action

public enum SessionAgentAction: Sendable {
  case interruptByUser
  case setMetadata(@Sendable (inout SessionMetadata) -> Void)

  case inference(AutoRetryInference.Action)
}

// MARK: - Interruption

public enum SessionAgentInterruption: Sendable {
  case userInitiated
}

// MARK: - Tool Result

public struct SessionAgentToolResult: Sendable {
}

// MARK: - Persistence Diff

public struct SessionAgentPersistenceDiff: Sendable {
}

// MARK: - Behavior

public struct SessionAgentBehavior: AgentBehavior {
  public let inference = AutoRetryInference()

  public typealias State = SessionAgentState
  public typealias Action = SessionAgentAction
  public typealias Interruption = SessionAgentInterruption
  public typealias ToolResult = SessionAgentToolResult
  public typealias PersistenceDiff = SessionAgentPersistenceDiff

  public func handle(_ action: Action, state: inout State) -> Interruption? {
    switch action {
    case .interruptByUser:
      return .userInitiated

    case .setMetadata(let body):
      body(&state.metadata)

    case .inference(let childAction):
      fatalError()
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

  public func infer(context: Context, state: inout State) -> DeferredExecution<Action, Interruption, AssistantMessage> {
    let model = state.metadata.model

    return inference.infer(
      model: model, context: context, options: .init(), interruption: Interruption.self)
      .map(Action.inference)
  }

  public func startToolCall(_ call: ToolCall, state: inout State) -> DeferredExecution<Action, Interruption, ToolResult> {
    fatalError()
  }

  public func performCompaction(state: inout State) -> DeferredExecution<Action, Interruption, Void> {
    fatalError()
  }

  public func persistAssistantEntry(_ message: AssistantMessage, state: inout State) {}
  public func persistToolResult(_ result: ToolResult, for call: ToolCall, state: inout State) {}

  public func diff(from oldState: State, to newState: State) -> PersistenceDiff? { nil }
  public func persist(_ diff: PersistenceDiff) async throws {}
}
