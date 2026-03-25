import Foundation
import WuhuAI

public struct WuhuMountContextEntry: Sendable, Hashable, Codable {
  public var mountID: String
  public var name: String
  public var path: String
  public var text: String

  public init(mountID: String, name: String, path: String, text: String) {
    self.mountID = mountID
    self.name = name
    self.path = path
    self.text = text
  }
}

public struct WuhuTextContextEntry: Sendable, Hashable, Codable {
  public var source: String
  public var mountID: String?
  public var profileName: String?
  public var text: String

  public init(source: String, mountID: String? = nil, profileName: String? = nil, text: String) {
    self.source = source
    self.mountID = mountID
    self.profileName = profileName
    self.text = text
  }
}

public enum WuhuKnownCustomEntry: Sendable, Hashable {
  case mountContext(WuhuMountContextEntry)
  case agentsContext(WuhuTextContextEntry)
  case skillsContext(WuhuTextContextEntry)
  case llmRetry(WuhuLLMRetryEvent)
  case llmGiveUp(WuhuLLMGiveUpEvent)

  public init?(customType: String, data: JSONValue?) {
    switch customType {
    case WuhuCustomMessageTypes.mountContext:
      guard let data, let entry = decodeFromJSONValue(data, as: WuhuMountContextEntry.self) else { return nil }
      self = .mountContext(entry)
    case WuhuCustomMessageTypes.agentsContext:
      guard let data, let entry = decodeFromJSONValue(data, as: WuhuTextContextEntry.self) else { return nil }
      self = .agentsContext(entry)
    case WuhuCustomMessageTypes.skillsContext:
      guard let data, let entry = decodeFromJSONValue(data, as: WuhuTextContextEntry.self) else { return nil }
      self = .skillsContext(entry)
    case WuhuLLMCustomEntryTypes.retry:
      guard let data, let entry = decodeFromJSONValue(data, as: WuhuLLMRetryEvent.self) else { return nil }
      self = .llmRetry(entry)
    case WuhuLLMCustomEntryTypes.giveUp:
      guard let data, let entry = decodeFromJSONValue(data, as: WuhuLLMGiveUpEvent.self) else { return nil }
      self = .llmGiveUp(entry)
    default:
      return nil
    }
  }

  public var customType: String {
    switch self {
    case .mountContext:
      WuhuCustomMessageTypes.mountContext
    case .agentsContext:
      WuhuCustomMessageTypes.agentsContext
    case .skillsContext:
      WuhuCustomMessageTypes.skillsContext
    case .llmRetry:
      WuhuLLMCustomEntryTypes.retry
    case .llmGiveUp:
      WuhuLLMCustomEntryTypes.giveUp
    }
  }

  public var data: JSONValue? {
    switch self {
    case let .mountContext(entry):
      try? WuhuJSON.encoder.encodeToJSONValue(entry)
    case let .agentsContext(entry):
      try? WuhuJSON.encoder.encodeToJSONValue(entry)
    case let .skillsContext(entry):
      try? WuhuJSON.encoder.encodeToJSONValue(entry)
    case let .llmRetry(event):
      event.toJSONValue()
    case let .llmGiveUp(event):
      event.toJSONValue()
    }
  }
}

public extension WuhuEntryPayload {
  static func knownCustom(_ entry: WuhuKnownCustomEntry) -> Self {
    .custom(customType: entry.customType, data: entry.data)
  }

  var knownCustomEntry: WuhuKnownCustomEntry? {
    guard case let .custom(customType, data) = self else { return nil }
    return .init(customType: customType, data: data)
  }
}

private func decodeFromJSONValue<T: Decodable>(_ value: JSONValue, as _: T.Type) -> T? {
  guard let data = try? WuhuJSON.encoder.encode(value) else { return nil }
  return try? WuhuJSON.decoder.decode(T.self, from: data)
}
