import Foundation

public enum WuhuMountTemplateType: String, Sendable, Codable, Hashable {
  case folder
}

/// A recipe for producing a mount. Replaces `WuhuEnvironmentDefinition`.
public struct WuhuMountTemplate: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var name: String
  public var type: WuhuMountTemplateType
  public var templatePath: String
  public var workspacesPath: String
  public var startupScript: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    type: WuhuMountTemplateType,
    templatePath: String,
    workspacesPath: String,
    startupScript: String? = nil,
    createdAt: Date,
    updatedAt: Date,
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.templatePath = templatePath
    self.workspacesPath = workspacesPath
    self.startupScript = startupScript
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WuhuCreateMountTemplateRequest: Sendable, Hashable, Codable {
  public var name: String
  public var type: WuhuMountTemplateType
  public var templatePath: String
  public var workspacesPath: String
  public var startupScript: String?

  public init(
    name: String,
    type: WuhuMountTemplateType,
    templatePath: String,
    workspacesPath: String,
    startupScript: String? = nil,
  ) {
    self.name = name
    self.type = type
    self.templatePath = templatePath
    self.workspacesPath = workspacesPath
    self.startupScript = startupScript
  }
}

public struct WuhuUpdateMountTemplateRequest: Sendable, Hashable, Codable {
  public var name: String?
  public var templatePath: String?
  public var workspacesPath: String?
  /// Nil means "not provided"; `.some(nil)` means "explicitly clear".
  public var startupScript: String??

  public init(
    name: String? = nil,
    templatePath: String? = nil,
    workspacesPath: String? = nil,
    startupScript: String?? = nil,
  ) {
    self.name = name
    self.templatePath = templatePath
    self.workspacesPath = workspacesPath
    self.startupScript = startupScript
  }
}
