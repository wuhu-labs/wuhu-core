import Foundation
import WuhuAI

public enum SessionItemContent: Equatable, Sendable {
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)
  case user(SessionUserMessage)
  case interruption(SessionInterruptionMessage)

  var assistant: AssistantMessage? {
    if case let .assistant(v) = self { v } else { nil }
  }

  var toolResult: ToolResultMessage? {
    if case let .toolResult(v) = self { v } else { nil }
  }
}

public struct SessionItem: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var content: SessionItemContent

  public init(id: UUID, content: SessionItemContent) {
    self.id = id
    self.content = content
  }

  public var timestamp: Date {
    switch content {
    case .assistant(let m):
      return m.timestamp
    case .toolResult(let m):
      return m.timestamp
    case .user(let m):
      return m.initiation.timestamp
    case .interruption(let m):
      return m.initiation.timestamp
    }
  }
}

public struct UserInitiation: Hashable, Sendable {
  public var user: String
  public var timestamp: Date
  public var timeZoneOffset: Int

  public var timestampString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = .gmt
    return formatter.string(from: timestamp.addingTimeInterval(TimeInterval(timeZoneOffset)))
  }

  public func toMessageHeader() -> String {
    "<\(user)> <\(timestampString)>"
  }
}

public struct SessionUserMessage: Equatable, Sendable {
  public var initiation: UserInitiation
  public var content: [ContentBlock]

  public func toWuhuAIUserMessage() -> WuhuAI.UserMessage {
    var content = self.content
    let prefix = initiation.toMessageHeader() + "\n\n"

    if case .text(let text) = content.first {
      content[0] = .text(prefix + text.text)
    } else {
      content.insert(.text(prefix), at: 0)
    }

    return .init(content: content, timestamp: initiation.timestamp)
  }
}

public struct SessionInterruptionMessage: Equatable, Sendable {
  public var initiation: UserInitiation

  public func toWuhuAIUserMessage() -> WuhuAI.UserMessage {
    let text = "Interrupted by user \(initiation.user) at \(initiation.timestampString)"
    return .init(content: [.text(text)], timestamp: initiation.timestamp)
  }
}

extension SessionItemContent {
  func toWuhuAIMessage() -> WuhuAI.Message? {
    switch self {
    case .assistant(let m):
      return .assistant(m)
    case .toolResult(let m):
      return .toolResult(m)
    case .user(let m):
      return .user(m.toWuhuAIUserMessage())
    case .interruption(let m):
      return .user(m.toWuhuAIUserMessage())
    }
  }
}
