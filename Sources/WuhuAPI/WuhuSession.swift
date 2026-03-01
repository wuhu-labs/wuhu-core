import Foundation

public struct WuhuSession: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var provider: WuhuProvider
  public var model: String
  /// Working directory for tool execution. Nil if the session has no mount (pure chat).
  public var cwd: String?
  public var parentSessionID: String?
  /// User-supplied custom title. When non-nil, clients should display this instead of the
  /// auto-derived title (e.g., first user message).
  public var customTitle: String?
  /// When `true` the session is archived. Archived sessions are hidden from
  /// the default list view but remain in the database and can be unarchived.
  public var isArchived: Bool
  public var createdAt: Date
  public var updatedAt: Date
  public var headEntryID: Int64
  public var tailEntryID: Int64

  public init(
    id: String,
    provider: WuhuProvider,
    model: String,
    cwd: String? = nil,
    parentSessionID: String? = nil,
    customTitle: String? = nil,
    isArchived: Bool = false,
    createdAt: Date,
    updatedAt: Date,
    headEntryID: Int64,
    tailEntryID: Int64,
  ) {
    self.id = id
    self.provider = provider
    self.model = model
    self.cwd = cwd
    self.parentSessionID = parentSessionID
    self.customTitle = customTitle
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.headEntryID = headEntryID
    self.tailEntryID = tailEntryID
  }

  enum CodingKeys: String, CodingKey {
    case id
    case provider
    case model
    case cwd
    case parentSessionID
    case customTitle
    case isArchived
    case createdAt
    case updatedAt
    case headEntryID
    case tailEntryID
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    provider = try c.decode(WuhuProvider.self, forKey: .provider)
    model = try c.decode(String.self, forKey: .model)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
    customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
    isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    headEntryID = try c.decode(Int64.self, forKey: .headEntryID)
    tailEntryID = try c.decode(Int64.self, forKey: .tailEntryID)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(provider, forKey: .provider)
    try c.encode(model, forKey: .model)
    try c.encodeIfPresent(cwd, forKey: .cwd)
    try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
    try c.encodeIfPresent(customTitle, forKey: .customTitle)
    try c.encode(isArchived, forKey: .isArchived)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encode(headEntryID, forKey: .headEntryID)
    try c.encode(tailEntryID, forKey: .tailEntryID)
  }
}
