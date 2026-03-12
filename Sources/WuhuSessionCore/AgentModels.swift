import Foundation
import PiAI

public struct AgentState: Sendable, Hashable {
  public var transcript: Transcript
  public var steerQueue: [QueuedMessage]
  public var followUpQueue: [QueuedMessage]
  public var notificationQueue: [QueuedMessage]
  public var activeToolCalls: [ToolRuntimeState]
  public var assistantDraft: AssistantDraft?
  public var status: SessionStatus
  public var lastError: String?

  public init(
    transcript: Transcript = .init(),
    steerQueue: [QueuedMessage] = [],
    followUpQueue: [QueuedMessage] = [],
    notificationQueue: [QueuedMessage] = [],
    activeToolCalls: [ToolRuntimeState] = [],
    assistantDraft: AssistantDraft? = nil,
    status: SessionStatus = .idle,
    lastError: String? = nil
  ) {
    self.transcript = transcript
    self.steerQueue = steerQueue
    self.followUpQueue = followUpQueue
    self.notificationQueue = notificationQueue
    self.activeToolCalls = activeToolCalls
    self.assistantDraft = assistantDraft
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

public enum UserMessageLane: String, Sendable, Hashable {
  case steer
  case followUp
}

public struct QueuedMessage: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var text: String
  public var preserveThinking: Bool
  public var timestamp: Date

  public init(id: UUID, text: String, preserveThinking: Bool = false, timestamp: Date) {
    self.id = id
    self.text = text
    self.preserveThinking = preserveThinking
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
  case process
}

public struct AssistantDraft: Identifiable, Sendable, Hashable {
  public var id: UUID { responseID }
  public var responseID: UUID
  public var text: String
  public var startedAt: Date
  public var updatedAt: Date

  public init(responseID: UUID, text: String = "", startedAt: Date, updatedAt: Date) {
    self.responseID = responseID
    self.text = text
    self.startedAt = startedAt
    self.updatedAt = updatedAt
  }
}

public protocol SemanticEntry: Sendable, Hashable {}

public struct AnySemanticEntry: Sendable, Hashable {
  private let box: any SemanticEntryBox
  public let typeDescription: String

  public init<Entry: SemanticEntry>(_ entry: Entry) {
    self.box = ConcreteSemanticEntryBox(entry)
    self.typeDescription = String(reflecting: Entry.self)
  }

  public func unwrap<Entry: SemanticEntry>(as type: Entry.Type = Entry.self) -> Entry? {
    box.unwrap(as: type)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.box.isEqual(to: rhs.box)
  }

  public func hash(into hasher: inout Hasher) {
    box.hash(into: &hasher)
  }
}

private protocol SemanticEntryBox: Sendable {
  func isEqual(to other: any SemanticEntryBox) -> Bool
  func hash(into hasher: inout Hasher)
  func unwrap<Entry: SemanticEntry>(as type: Entry.Type) -> Entry?
}

private struct ConcreteSemanticEntryBox<Entry: SemanticEntry>: SemanticEntryBox {
  let entry: Entry

  init(_ entry: Entry) {
    self.entry = entry
  }

  func isEqual(to other: any SemanticEntryBox) -> Bool {
    guard let otherEntry: Entry = other.unwrap(as: Entry.self) else { return false }
    return entry == otherEntry
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(entry)
  }

  func unwrap<T: SemanticEntry>(as type: T.Type) -> T? {
    entry as? T
  }
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

      case .semantic:
        continue
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
  case semantic(SemanticEntryRecord)
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
    case let .semantic(entry):
      entry.id
    case let .systemMessage(entry):
      entry.id
    }
  }
}

public struct UserMessageEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var text: String
  public var lane: UserMessageLane
  public var preserveThinking: Bool
  public var timestamp: Date

  public init(
    id: UUID,
    text: String,
    lane: UserMessageLane,
    preserveThinking: Bool = false,
    timestamp: Date
  ) {
    self.id = id
    self.text = text
    self.lane = lane
    self.preserveThinking = preserveThinking
    self.timestamp = timestamp
  }
}

public enum AssistantCompletionState: String, Sendable, Hashable {
  case finished
  case interrupted
}

public struct AssistantTextEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var responseID: UUID
  public var text: String
  public var completion: AssistantCompletionState
  public var timestamp: Date

  public init(
    id: UUID,
    responseID: UUID,
    text: String,
    completion: AssistantCompletionState = .finished,
    timestamp: Date
  ) {
    self.id = id
    self.responseID = responseID
    self.text = text
    self.completion = completion
    self.timestamp = timestamp
  }
}

public struct ToolCallEntry: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var responseID: UUID
  public var toolCallID: String
  public var toolName: String
  public var arguments: JSONValue
  public var timestamp: Date

  public init(id: UUID, responseID: UUID, toolCallID: String, toolName: String, arguments: JSONValue, timestamp: Date) {
    self.id = id
    self.responseID = responseID
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

public struct SemanticEntryRecord: Identifiable, Sendable, Hashable {
  public var id: UUID
  public var entry: AnySemanticEntry
  public var timestamp: Date

  public init(id: UUID, entry: AnySemanticEntry, timestamp: Date) {
    self.id = id
    self.entry = entry
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
