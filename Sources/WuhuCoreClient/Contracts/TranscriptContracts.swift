import Foundation

/// A single transcript entry.
///
/// The transcript is the canonical ordered log for a session. Some entries are "message entries"
/// that become LLM input; others exist only for diagnostics / UX.
public struct TranscriptItem: Sendable, Hashable, Codable {
  public var id: TranscriptEntryID
  public var createdAt: Date
  public var entry: Entry

  public init(id: TranscriptEntryID, createdAt: Date, entry: Entry) {
    self.id = id
    self.createdAt = createdAt
    self.entry = entry
  }
}

/// Domain-level entry types. UI rendering and grouping are separate concerns.
public enum Entry: Sendable, Hashable, Codable {
  case message(MessageEntry)
  case marker(MarkerEntry)
  case tool(ToolEntry)
  case diagnostic(DiagnosticEntry)
}

/// A message that is eligible to be included in the LLM context.
public struct MessageEntry: Sendable, Hashable, Codable {
  public var author: Author
  public var content: MessageContent

  public init(author: Author, content: MessageContent) {
    self.author = author
    self.content = content
  }
}

/// A single part of a rich message content.
public enum MessageContentPart: Sendable, Hashable, Codable {
  case text(String)
  case image(blobURI: String, mimeType: String)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case blobURI
    case mimeType
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "text":
      self = try .text(c.decode(String.self, forKey: .text))
    case "image":
      self = try .image(
        blobURI: c.decode(String.self, forKey: .blobURI),
        mimeType: c.decode(String.self, forKey: .mimeType),
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c,
        debugDescription: "Unknown MessageContentPart type: \(type)",
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .text(text):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
    case let .image(blobURI, mimeType):
      try c.encode("image", forKey: .type)
      try c.encode(blobURI, forKey: .blobURI)
      try c.encode(mimeType, forKey: .mimeType)
    }
  }
}

public enum MessageContent: Sendable, Hashable, Codable {
  case text(String)
  case richContent([MessageContentPart])

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case parts
  }

  public init(from decoder: any Decoder) throws {
    // Try tagged format first.
    if let c = try? decoder.container(keyedBy: CodingKeys.self),
       let type = try? c.decode(String.self, forKey: .type)
    {
      switch type {
      case "text":
        self = try .text(c.decode(String.self, forKey: .text))
        return
      case "rich":
        self = try .richContent(c.decode([MessageContentPart].self, forKey: .parts))
        return
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .type, in: c,
          debugDescription: "Unknown MessageContent type: \(type)",
        )
      }
    }

    // Backward-compat: try decoding as a bare string (old `.text` format from synthesized Codable).
    let container = try decoder.singleValueContainer()
    if let textObj = try? container.decode(TextWrapper.self) {
      self = .text(textObj.text)
      return
    }

    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Unable to decode MessageContent"),
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .text(text):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
    case let .richContent(parts):
      try c.encode("rich", forKey: .type)
      try c.encode(parts, forKey: .parts)
    }
  }
}

/// Helper for backward-compatible decoding of old synthesized Codable `.text` payloads.
private struct TextWrapper: Decodable {
  var text: String
}

/// Non-message markers that help describe execution boundaries or session lifecycle.
public enum MarkerEntry: Sendable, Hashable, Codable {
  case executionStopped(by: Author)
  case executionResumed(trigger: Author)
  case participantJoined(Author)
}

/// Tool execution surface (can be rendered and/or summarized in UI).
public struct ToolEntry: Sendable, Hashable, Codable {
  public var name: String
  public var detail: String?

  public init(name: String, detail: String? = nil) {
    self.name = name
    self.detail = detail
  }
}

/// Diagnostic / non-causal entries (transport errors, server overload, etc.).
public struct DiagnosticEntry: Sendable, Hashable, Codable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}

/// A page of transcript items for catch-up.
public struct TranscriptPage: Sendable, Hashable, Codable {
  public var items: [TranscriptItem]
  public var nextCursor: TranscriptCursor?

  public init(items: [TranscriptItem], nextCursor: TranscriptCursor?) {
    self.items = items
    self.nextCursor = nextCursor
  }
}
