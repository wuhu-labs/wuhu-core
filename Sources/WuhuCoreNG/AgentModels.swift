import Foundation
import PiAI

public struct AgentState: Sendable, Hashable {
  public var transcript: Transcript
  public var steerQueue: [QueuedMessage]
  public var followUpQueue: [QueuedMessage]
  public var notificationQueue: [QueuedMessage]
  public var activeToolCalls: [ToolRuntimeState]
  public var status: SessionStatus
  public var lastError: String?

  public init(
    transcript: Transcript = .init(),
    steerQueue: [QueuedMessage] = [],
    followUpQueue: [QueuedMessage] = [],
    notificationQueue: [QueuedMessage] = [],
    activeToolCalls: [ToolRuntimeState] = [],
    status: SessionStatus = .idle,
    lastError: String? = nil
  ) {
    self.transcript = transcript
    self.steerQueue = steerQueue
    self.followUpQueue = followUpQueue
    self.notificationQueue = notificationQueue
    self.activeToolCalls = activeToolCalls
    self.status = status
    self.lastError = lastError
  }
}

public enum SessionStatus: String, Sendable, Hashable {
  case idle
  case running
  case waitingForTools
  case paused
}

public struct QueuedMessage: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var text: String
  public var timestamp: Date

  public init(id: UUID, text: String, timestamp: Date) {
    self.id = id
    self.text = text
    self.timestamp = timestamp
  }
}

public struct ToolRuntimeState: Identifiable, Sendable, Hashable {
  public var id: String
  public var name: String
  public var kind: ToolRuntimeKind
  public var progress: [String]
  public var startedAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    kind: ToolRuntimeKind,
    progress: [String] = [],
    startedAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.progress = progress
    self.startedAt = startedAt
    self.updatedAt = updatedAt
  }
}

public enum ToolRuntimeKind: String, Sendable, Hashable {
  case persistent
  case join
}

public struct Transcript: Sendable, Hashable {
  public var entries: [TranscriptEntry]

  public init(entries: [TranscriptEntry] = []) {
    self.entries = entries
  }

  public mutating func append(_ entry: TranscriptEntry) {
    entries.append(entry)
  }

  public func contextMessages(model: Model) -> [Message] {
    var messages: [Message] = []
    var assistantBlocks: [ContentBlock] = []
    var assistantTimestamp: Date?

    func flushAssistant() {
      guard !assistantBlocks.isEmpty else { return }
      messages.append(
        .assistant(
          .init(
            provider: model.provider,
            model: model.id,
            content: assistantBlocks,
            stopReason: .stop,
            timestamp: assistantTimestamp ?? .distantPast
          )
        )
      )
      assistantBlocks = []
      assistantTimestamp = nil
    }

    for entry in entries {
      switch entry {
      case let .userMessage(message):
        flushAssistant()
        messages.append(.user(.init(content: [.text(message.text)], timestamp: message.timestamp)))

      case let .assistantText(message):
        assistantBlocks.append(.text(message.text))
        assistantTimestamp = message.timestamp

      case let .toolCall(call):
        assistantBlocks.append(
          .toolCall(
            .init(
              id: call.toolCallID,
              name: call.toolName,
              arguments: call.arguments
            )
          )
        )
        assistantTimestamp = call.timestamp

      case let .toolResult(result):
        flushAssistant()
        messages.append(
          .toolResult(
            .init(
              toolCallId: result.toolCallID,
              toolName: result.toolName,
              content: result.content,
              details: result.details,
              isError: result.isError,
              timestamp: result.timestamp
            )
          )
        )

      case let .systemMessage(message):
        flushAssistant()
        messages.append(.user(.init(content: [.text(message.text)], timestamp: message.timestamp)))
      }
    }

    flushAssistant()
    return messages
  }
}

public enum TranscriptEntry: Identifiable, Sendable, Hashable {
  case userMessage(UserMessageEntry)
  case assistantText(AssistantTextEntry)
  case toolCall(ToolCallEntry)
  case toolResult(ToolResultEntry)
  case systemMessage(SystemMessageEntry)

  public var id: UUID {
    switch self {
    case let .userMessage(entry):
      entry.id
    case let .assistantText(entry):
      entry.id
    case let .toolCall(entry):
      entry.id
    case let .toolResult(entry):
      entry.id
    case let .systemMessage(entry):
      entry.id
    }
  }
}

public struct UserMessageEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var text: String
  public var timestamp: Date

  public init(id: UUID, text: String, timestamp: Date) {
    self.id = id
    self.text = text
    self.timestamp = timestamp
  }
}

public struct AssistantTextEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var text: String
  public var timestamp: Date

  public init(id: UUID, text: String, timestamp: Date) {
    self.id = id
    self.text = text
    self.timestamp = timestamp
  }
}

public struct ToolCallEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var toolCallID: String
  public var toolName: String
  public var arguments: JSONValue
  public var timestamp: Date

  public init(id: UUID, toolCallID: String, toolName: String, arguments: JSONValue, timestamp: Date) {
    self.id = id
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.arguments = arguments
    self.timestamp = timestamp
  }
}

public struct ToolResultEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var toolCallID: String
  public var toolName: String
  public var content: [ContentBlock]
  public var details: JSONValue
  public var isError: Bool
  public var timestamp: Date

  public init(
    id: UUID,
    toolCallID: String,
    toolName: String,
    content: [ContentBlock],
    details: JSONValue = .object([:]),
    isError: Bool = false,
    timestamp: Date
  ) {
    self.id = id
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.content = content
    self.details = details
    self.isError = isError
    self.timestamp = timestamp
  }
}

public struct SystemMessageEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var kind: SystemMessageKind
  public var text: String
  public var timestamp: Date

  public init(id: UUID, kind: SystemMessageKind, text: String, timestamp: Date) {
    self.id = id
    self.kind = kind
    self.text = text
    self.timestamp = timestamp
  }
}

public enum SystemMessageKind: String, Sendable, Hashable {
  case control
  case notification
}
