import Foundation
import PiAI

public enum WuhuContentBlock: Sendable, Hashable, Codable {
  case text(text: String, signature: String?)
  case toolCall(id: String, name: String, arguments: JSONValue)
  case reasoning(id: String, encryptedContent: String?, summary: [JSONValue])
  case image(blobURI: String, mimeType: String)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case signature
    case id
    case name
    case arguments
    case encryptedContent = "encrypted_content"
    case summary
    case blobURI
    case mimeType
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "text":
      self = try .text(text: c.decode(String.self, forKey: .text), signature: c.decodeIfPresent(String.self, forKey: .signature))
    case "tool_call":
      self = try .toolCall(
        id: c.decode(String.self, forKey: .id),
        name: c.decode(String.self, forKey: .name),
        arguments: c.decode(JSONValue.self, forKey: .arguments),
      )
    case "reasoning":
      self = try .reasoning(
        id: c.decode(String.self, forKey: .id),
        encryptedContent: c.decodeIfPresent(String.self, forKey: .encryptedContent),
        summary: c.decodeIfPresent([JSONValue].self, forKey: .summary) ?? [],
      )
    case "image":
      self = try .image(
        blobURI: c.decode(String.self, forKey: .blobURI),
        mimeType: c.decode(String.self, forKey: .mimeType),
      )
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown content block type: \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .text(text, signature):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
      try c.encodeIfPresent(signature, forKey: .signature)
    case let .toolCall(id, name, arguments):
      try c.encode("tool_call", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(name, forKey: .name)
      try c.encode(arguments, forKey: .arguments)
    case let .reasoning(id, encryptedContent, summary):
      try c.encode("reasoning", forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(encryptedContent, forKey: .encryptedContent)
      try c.encode(summary, forKey: .summary)
    case let .image(blobURI, mimeType):
      try c.encode("image", forKey: .type)
      try c.encode(blobURI, forKey: .blobURI)
      try c.encode(mimeType, forKey: .mimeType)
    }
  }

  /// Convert from PiAI ContentBlock.
  ///
  /// For `.image`, the `data` field of PiAI's `ImageContent` is stored directly as `blobURI`.
  /// Callers must ensure this field is a blob URI (not base64) before persisting.
  /// When building LLM context, callers must hydrate blob URIs back to base64 after calling `toPi()`.
  public static func fromPi(_ b: ContentBlock) -> WuhuContentBlock {
    switch b {
    case let .text(t):
      .text(text: t.text, signature: t.signature)
    case let .toolCall(c):
      .toolCall(id: c.id, name: c.name, arguments: c.arguments)
    case let .reasoning(r):
      .reasoning(id: r.id, encryptedContent: r.encryptedContent, summary: r.summary)
    case let .image(img):
      .image(blobURI: img.data, mimeType: img.mimeType)
    }
  }

  /// Convert to PiAI ContentBlock.
  ///
  /// For `.image`, the `blobURI` is placed in the `data` field of `ImageContent`.
  /// Callers must hydrate blob URIs to base64 after calling this method before sending to the LLM.
  public func toPi() -> ContentBlock {
    switch self {
    case let .text(text, signature):
      .text(.init(text: text, signature: signature))
    case let .toolCall(id, name, arguments):
      .toolCall(.init(id: id, name: name, arguments: arguments))
    case let .reasoning(id, encryptedContent, summary):
      .reasoning(.init(id: id, encryptedContent: encryptedContent, summary: summary))
    case let .image(blobURI, mimeType):
      .image(.init(data: blobURI, mimeType: mimeType))
    }
  }
}

public struct WuhuUsage: Sendable, Hashable, Codable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int

  public init(inputTokens: Int, outputTokens: Int, totalTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
  }

  public static func fromPi(_ u: Usage) -> WuhuUsage {
    .init(inputTokens: u.inputTokens, outputTokens: u.outputTokens, totalTokens: u.totalTokens)
  }

  public func toPi() -> Usage {
    .init(inputTokens: inputTokens, outputTokens: outputTokens, totalTokens: totalTokens)
  }
}

public struct WuhuUserMessage: Sendable, Hashable, Codable {
  public static let unknownUser = "unknown_user"

  public var user: String
  public var content: [WuhuContentBlock]
  public var timestamp: Date

  public init(user: String = Self.unknownUser, content: [WuhuContentBlock], timestamp: Date) {
    self.user = user
    self.content = content
    self.timestamp = timestamp
  }

  enum CodingKeys: String, CodingKey {
    case user
    case content
    case timestamp
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    user = try c.decodeIfPresent(String.self, forKey: .user) ?? Self.unknownUser
    content = try c.decode([WuhuContentBlock].self, forKey: .content)
    timestamp = try c.decode(Date.self, forKey: .timestamp)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(user, forKey: .user)
    try c.encode(content, forKey: .content)
    try c.encode(timestamp, forKey: .timestamp)
  }

  public static func fromPi(_ m: UserMessage) -> WuhuUserMessage {
    .init(user: unknownUser, content: m.content.map(WuhuContentBlock.fromPi), timestamp: m.timestamp)
  }

  public func toPi() -> UserMessage {
    .init(content: content.map { $0.toPi() }, timestamp: timestamp)
  }
}

public struct WuhuAssistantMessage: Sendable, Hashable, Codable {
  public var provider: WuhuProvider
  public var model: String
  public var content: [WuhuContentBlock]
  public var usage: WuhuUsage?
  public var stopReason: String
  public var errorMessage: String?
  public var timestamp: Date

  public init(
    provider: WuhuProvider,
    model: String,
    content: [WuhuContentBlock],
    usage: WuhuUsage?,
    stopReason: String,
    errorMessage: String?,
    timestamp: Date,
  ) {
    self.provider = provider
    self.model = model
    self.content = content
    self.usage = usage
    self.stopReason = stopReason
    self.errorMessage = errorMessage
    self.timestamp = timestamp
  }

  public static func fromPi(_ m: AssistantMessage) -> WuhuAssistantMessage {
    .init(
      provider: .init(rawValue: m.provider.rawValue) ?? .openai,
      model: m.model,
      content: m.content.map(WuhuContentBlock.fromPi),
      usage: m.usage.map(WuhuUsage.fromPi),
      stopReason: m.stopReason.rawValue,
      errorMessage: m.errorMessage,
      timestamp: m.timestamp,
    )
  }

  public func toPi() -> AssistantMessage {
    .init(
      provider: provider.piProvider,
      model: model,
      content: content.map { $0.toPi() },
      usage: usage?.toPi(),
      stopReason: StopReason(rawValue: stopReason) ?? .stop,
      errorMessage: errorMessage,
      timestamp: timestamp,
    )
  }
}

public struct WuhuToolResultMessage: Sendable, Hashable, Codable {
  public var toolCallId: String
  public var toolName: String
  public var content: [WuhuContentBlock]
  public var details: JSONValue
  public var isError: Bool
  public var timestamp: Date

  public init(
    toolCallId: String,
    toolName: String,
    content: [WuhuContentBlock],
    details: JSONValue,
    isError: Bool,
    timestamp: Date,
  ) {
    self.toolCallId = toolCallId
    self.toolName = toolName
    self.content = content
    self.details = details
    self.isError = isError
    self.timestamp = timestamp
  }

  public static func fromPi(_ m: ToolResultMessage) -> WuhuToolResultMessage {
    .init(
      toolCallId: m.toolCallId,
      toolName: m.toolName,
      content: m.content.map(WuhuContentBlock.fromPi),
      details: m.details,
      isError: m.isError,
      timestamp: m.timestamp,
    )
  }

  public func toPi() -> ToolResultMessage {
    .init(
      toolCallId: toolCallId,
      toolName: toolName,
      content: content.map { $0.toPi() },
      details: details,
      isError: isError,
      timestamp: timestamp,
    )
  }
}

public struct WuhuCustomMessage: Sendable, Hashable, Codable {
  public var customType: String
  public var content: [WuhuContentBlock]
  public var details: JSONValue?
  public var display: Bool
  public var timestamp: Date

  public init(
    customType: String,
    content: [WuhuContentBlock],
    details: JSONValue?,
    display: Bool,
    timestamp: Date,
  ) {
    self.customType = customType
    self.content = content
    self.details = details
    self.display = display
    self.timestamp = timestamp
  }
}

public enum WuhuPersistedMessage: Sendable, Hashable, Codable {
  case user(WuhuUserMessage)
  case assistant(WuhuAssistantMessage)
  case toolResult(WuhuToolResultMessage)
  case customMessage(WuhuCustomMessage)
  case unknown(role: String, payload: JSONValue)

  enum CodingKeys: String, CodingKey {
    case role
    case message
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let role = try c.decode(String.self, forKey: .role)
    switch role {
    case "user":
      self = try .user(c.decode(WuhuUserMessage.self, forKey: .message))
    case "assistant":
      self = try .assistant(c.decode(WuhuAssistantMessage.self, forKey: .message))
    case "tool_result":
      self = try .toolResult(c.decode(WuhuToolResultMessage.self, forKey: .message))
    case "custom_message":
      self = try .customMessage(c.decode(WuhuCustomMessage.self, forKey: .message))
    default:
      self = try .unknown(role: role, payload: (c.decodeIfPresent(JSONValue.self, forKey: .payload)) ?? .null)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .user(m):
      try c.encode("user", forKey: .role)
      try c.encode(m, forKey: .message)
    case let .assistant(m):
      try c.encode("assistant", forKey: .role)
      try c.encode(m, forKey: .message)
    case let .toolResult(m):
      try c.encode("tool_result", forKey: .role)
      try c.encode(m, forKey: .message)
    case let .customMessage(m):
      try c.encode("custom_message", forKey: .role)
      try c.encode(m, forKey: .message)
    case let .unknown(role, payload):
      try c.encode(role, forKey: .role)
      try c.encode(payload, forKey: .payload)
    }
  }

  public static func fromPi(_ m: Message) -> WuhuPersistedMessage {
    switch m {
    case let .user(u):
      .user(.fromPi(u))
    case let .assistant(a):
      .assistant(.fromPi(a))
    case let .toolResult(t):
      .toolResult(.fromPi(t))
    }
  }

  public func toPiMessage() -> Message? {
    switch self {
    case let .user(u):
      .user(u.toPi())
    case let .assistant(a):
      .assistant(a.toPi())
    case let .toolResult(t):
      .toolResult(t.toPi())
    case let .customMessage(c):
      .user(.init(content: c.content.map { $0.toPi() }, timestamp: c.timestamp))
    case .unknown:
      nil
    }
  }
}
