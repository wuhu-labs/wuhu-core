import Foundation

public struct WuhuUser: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var username: String
  public var kind: WuhuUserKind
  public var createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: String,
    username: String,
    kind: WuhuUserKind = .human,
    createdAt: Date,
    updatedAt: Date,
    deletedAt: Date? = nil,
  ) {
    self.id = id
    self.username = username
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  public var isDeleted: Bool {
    deletedAt != nil
  }
}

public enum WuhuUserKind: String, Sendable, Hashable, Codable {
  case human
  case bot
}

public struct WuhuCreateUserRequest: Sendable, Hashable, Codable {
  public var username: String
  public var kind: WuhuUserKind?

  public init(username: String, kind: WuhuUserKind? = nil) {
    self.username = username
    self.kind = kind
  }
}
