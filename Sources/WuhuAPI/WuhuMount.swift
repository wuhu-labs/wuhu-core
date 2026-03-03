import Foundation

/// A concrete resolved directory bound to a session.
public struct WuhuMount: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var sessionID: String
  public var name: String
  public var path: String
  public var mountTemplateID: String?
  public var isPrimary: Bool
  public var runnerID: RunnerID
  public var createdAt: Date

  public init(
    id: String,
    sessionID: String,
    name: String,
    path: String,
    mountTemplateID: String? = nil,
    isPrimary: Bool,
    runnerID: RunnerID = .local,
    createdAt: Date,
  ) {
    self.id = id
    self.sessionID = sessionID
    self.name = name
    self.path = path
    self.mountTemplateID = mountTemplateID
    self.isPrimary = isPrimary
    self.runnerID = runnerID
    self.createdAt = createdAt
  }
}

/// Runner identification.
public enum RunnerID: Sendable, Hashable, Codable {
  case local
  case remote(name: String)

  // MARK: - Codable

  /// Encodes as a plain string: "local" or "remote:<name>".
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(wireValue)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    if raw == "local" {
      self = .local
    } else if raw.hasPrefix("remote:") {
      let name = String(raw.dropFirst("remote:".count))
      self = .remote(name: name)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RunnerID: \(raw)")
    }
  }

  /// Wire representation: "local" or "remote:<name>".
  public var wireValue: String {
    switch self {
    case .local: "local"
    case let .remote(name): "remote:\(name)"
    }
  }

  /// Human-readable display name.
  public var displayName: String {
    switch self {
    case .local: "local"
    case let .remote(name): name
    }
  }
}
