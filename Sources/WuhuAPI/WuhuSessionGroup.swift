import Foundation

public struct WuhuSessionGroup: Sendable, Hashable, Codable, Identifiable {
  public static let defaultID = "inbox"

  public var id: String
  public var name: String
  public var profileName: String?
  public var isDefault: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    profileName: String? = nil,
    isDefault: Bool = false,
    createdAt: Date,
    updatedAt: Date,
  ) {
    self.id = id
    self.name = name
    self.profileName = profileName
    self.isDefault = isDefault
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WuhuProfile: Sendable, Hashable, Codable, Identifiable {
  public var name: String
  public var agentsPath: String

  public var id: String { name }

  public init(name: String, agentsPath: String) {
    self.name = name
    self.agentsPath = agentsPath
  }
}
