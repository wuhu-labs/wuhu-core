import Foundation

/// A concrete resolved directory bound to a session.
public struct WuhuMount: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var sessionID: String
  public var name: String
  public var path: String
  public var mountTemplateID: String?
  public var isPrimary: Bool
  public var createdAt: Date

  public init(
    id: String,
    sessionID: String,
    name: String,
    path: String,
    mountTemplateID: String? = nil,
    isPrimary: Bool,
    createdAt: Date,
  ) {
    self.id = id
    self.sessionID = sessionID
    self.name = name
    self.path = path
    self.mountTemplateID = mountTemplateID
    self.isPrimary = isPrimary
    self.createdAt = createdAt
  }
}

/// Runner identification. Only `.local` is implemented for now.
public enum RunnerID: String, Sendable, Hashable, Codable {
  case local
}
