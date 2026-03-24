import Foundation

public struct WuhuSessionSummary: Sendable, Hashable, Codable, Identifiable {
  public enum MessageRole: String, Sendable, Hashable, Codable {
    case assistant
    case user
  }

  public var session: WuhuSession
  public var displayTitle: String
  public var firstUserMessageText: String?
  public var lastMessageRole: MessageRole?
  public var lastMessageText: String?

  public var id: String { session.id }

  public init(
    session: WuhuSession,
    displayTitle: String,
    firstUserMessageText: String? = nil,
    lastMessageRole: MessageRole? = nil,
    lastMessageText: String? = nil,
  ) {
    self.session = session
    self.displayTitle = displayTitle
    self.firstUserMessageText = firstUserMessageText
    self.lastMessageRole = lastMessageRole
    self.lastMessageText = lastMessageText
  }
}
