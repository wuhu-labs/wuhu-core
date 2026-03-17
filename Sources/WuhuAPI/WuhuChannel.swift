import Foundation

public struct WuhuChannel: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var name: String
  public var topic: String?
  public var kind: WuhuChannelKind
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    topic: String? = nil,
    kind: WuhuChannelKind = .channel,
    createdAt: Date,
    updatedAt: Date,
  ) {
    self.id = id
    self.name = name
    self.topic = topic
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum WuhuChannelKind: String, Sendable, Hashable, Codable {
  case channel
  case dm
}

public struct WuhuChannelMember: Sendable, Hashable, Codable {
  public var channelID: String
  public var userID: String
  public var username: String
  public var role: WuhuChannelMemberRole
  public var joinedAt: Date

  public init(
    channelID: String,
    userID: String,
    username: String,
    role: WuhuChannelMemberRole = .member,
    joinedAt: Date,
  ) {
    self.channelID = channelID
    self.userID = userID
    self.username = username
    self.role = role
    self.joinedAt = joinedAt
  }
}

public enum WuhuChannelMemberRole: String, Sendable, Hashable, Codable {
  case member
  case admin
}

public struct WuhuChannelMessage: Sendable, Hashable, Codable, Identifiable {
  public var id: Int64
  public var channelID: String
  public var authorID: String
  public var authorUsername: String
  public var content: String
  public var threadID: Int64?
  public var createdAt: Date

  public init(
    id: Int64,
    channelID: String,
    authorID: String,
    authorUsername: String,
    content: String,
    threadID: Int64? = nil,
    createdAt: Date,
  ) {
    self.id = id
    self.channelID = channelID
    self.authorID = authorID
    self.authorUsername = authorUsername
    self.content = content
    self.threadID = threadID
    self.createdAt = createdAt
  }
}

public struct WuhuCreateChannelRequest: Sendable, Hashable, Codable {
  public var name: String
  public var topic: String?
  public var kind: WuhuChannelKind?

  public init(name: String, topic: String? = nil, kind: WuhuChannelKind? = nil) {
    self.name = name
    self.topic = topic
    self.kind = kind
  }
}

public struct WuhuUpdateChannelRequest: Sendable, Hashable, Codable {
  public var name: String?
  /// Set to a non-nil value to update the topic. Set to empty string to clear it.
  public var topic: String?

  public init(name: String? = nil, topic: String? = nil) {
    self.name = name
    self.topic = topic
  }
}

public struct WuhuAddChannelMemberRequest: Sendable, Hashable, Codable {
  public var userID: String
  public var role: WuhuChannelMemberRole?

  public init(userID: String, role: WuhuChannelMemberRole? = nil) {
    self.userID = userID
    self.role = role
  }
}

public struct WuhuPostMessageRequest: Sendable, Hashable, Codable {
  public var content: String
  public var threadID: Int64?

  public init(content: String, threadID: Int64? = nil) {
    self.content = content
    self.threadID = threadID
  }
}
