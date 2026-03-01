import WuhuAPI

public extension MessageContent {
  /// Convert to an array of ``WuhuContentBlock`` for persistence.
  ///
  /// Both the `switch` over `MessageContent` and the inner `switch` over
  /// ``MessageContentPart`` are exhaustive, so adding a new variant to either
  /// enum will produce a compile-time error here instead of silently dropping
  /// content.
  func toContentBlocks() -> [WuhuContentBlock] {
    switch self {
    case let .text(t):
      [.text(text: t, signature: nil)]
    case let .richContent(parts):
      parts.map { part in
        switch part {
        case let .text(t):
          WuhuContentBlock.text(text: t, signature: nil)
        case let .image(blobURI, mimeType):
          WuhuContentBlock.image(blobURI: blobURI, mimeType: mimeType)
        }
      }
    }
  }
}
