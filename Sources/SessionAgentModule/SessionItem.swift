import Foundation
import WuhuAI

public enum SessionItemContent: Equatable, Sendable {
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)
  case user(SessionUserMessage)

  var assistant: AssistantMessage? {
    if case let .assistant(v) = self { v } else { nil }
  }

  var toolResult: ToolResultMessage? {
    if case let .toolResult(v) = self { v } else { nil }
  }
}

public struct SessionItem: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var createdAt: Date
  public var content: SessionItemContent

  public init(id: UUID, content: SessionItemContent, createdAt: Date) {
    self.id = id
    self.createdAt = createdAt
    self.content = content
  }

  public var timestamp: Date {
    switch content {
    case .assistant(let m):
      return m.timestamp
    case .toolResult(let m):
      return m.timestamp
    case .user(let m):
      return m.timestamp
    }
  }
}

public struct SessionUserMessage: Equatable, Sendable {
  public var user: String
  public var timestamp: Date
  public var timeZone: TimeZone
  public var content: [ContentBlock]

  var formattedTimestamp: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = timeZone
    return formatter.string(from: timestamp)
  }

  public func toWuhuAIUserMessage() -> WuhuAI.UserMessage {
    var content = self.content
    let prefix = "<\(user)> <\(formattedTimestamp)>\n\n"

    if case .text(let text) = content.first {
      content[0] = .text(prefix + text.text)
    } else {
      content.insert(.text(prefix), at: 0)
    }

    return .init(content: content, timestamp: timestamp)
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
    }
  }
}
