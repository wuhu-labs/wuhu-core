import Foundation
import Testing
import WuhuAPI
import WuhuCoreClient

struct MessageContentTests {
  @Test func textCodableRoundTrip() throws {
    let content = MessageContent.text("Hello, world!")
    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == content)
  }

  @Test func richContentCodableRoundTrip() throws {
    let content = MessageContent.richContent([
      .text("Check this image:"),
      .image(blobURI: "blob://sess-1/sha256-abc.png", mimeType: "image/png"),
    ])
    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == content)
  }

  @Test func textEncodesWithTypeTag() throws {
    let content = MessageContent.text("hello")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(content)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["type"] as? String == "text")
    #expect(json["text"] as? String == "hello")
  }

  @Test func richContentEncodesWithTypeTag() throws {
    let content = MessageContent.richContent([
      .text("test"),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(content)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["type"] as? String == "rich")
    #expect(json["parts"] != nil)
  }

  @Test func backwardCompatDecodeFromOldFormat() throws {
    // Old format without type tag: {"text":"Hello from legacy"}
    let oldJSON = #"{"text":"Hello from legacy"}"#
    let data = Data(oldJSON.utf8)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == .text("Hello from legacy"))
  }

  @Test func backwardCompatDecodeFromSynthesizedCodable() throws {
    // Pre-0.4.0 synthesized Codable produced {"text":{"_0":"can you hear me"}} for .text("can you hear me")
    let oldJSON = #"{"text":{"_0":"can you hear me"}}"#
    let data = Data(oldJSON.utf8)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == .text("can you hear me"))
  }

  @Test func backwardCompatDecodeFromNestedJournalEntry() throws {
    // Real-world journal payload from pre-0.4.0 DB
    let oldJSON = """
    {"enqueued":{"item":{"enqueuedAt":1772290896.6157079,"id":"eb7200d9-d465-4ba7-b78c-6c65777516a3","message":{"author":{"participant":{"_0":"minsheng","kind":"human"}},"content":{"text":{"_0":"can you hear me"}}}},"lane":"followUp"}}
    """
    let data = Data(oldJSON.utf8)
    // This should not throw — the MessageContent inside should decode via backward-compat path
    let entry = try JSONDecoder().decode(UserQueueJournalEntry.self, from: data)
    if case let .enqueued(lane, item) = entry {
      #expect(lane == .followUp)
      #expect(item.message.content == .text("can you hear me"))
    } else {
      Issue.record("Expected .enqueued, got \(entry)")
    }
  }

  @Test func messageContentPartTextRoundTrip() throws {
    let part = MessageContentPart.text("Hello")
    let data = try JSONEncoder().encode(part)
    let decoded = try JSONDecoder().decode(MessageContentPart.self, from: data)
    #expect(decoded == part)
  }

  @Test func messageContentPartImageRoundTrip() throws {
    let part = MessageContentPart.image(blobURI: "blob://s/file.png", mimeType: "image/png")
    let data = try JSONEncoder().encode(part)
    let decoded = try JSONDecoder().decode(MessageContentPart.self, from: data)
    #expect(decoded == part)
  }

  @Test func richContentWithMixedParts() throws {
    let content = MessageContent.richContent([
      .text("Before image"),
      .image(blobURI: "blob://sess-1/sha256-abc.png", mimeType: "image/png"),
      .text("After image"),
    ])
    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == content)
  }

  // MARK: - toContentBlocks

  @Test func toContentBlocks_textProducesSingleTextBlock() {
    let content = MessageContent.text("hello world")
    let blocks = content.toContentBlocks()
    #expect(blocks == [.text(text: "hello world", signature: nil)])
  }

  @Test func toContentBlocks_emptyTextProducesSingleEmptyBlock() {
    let content = MessageContent.text("")
    let blocks = content.toContentBlocks()
    #expect(blocks == [.text(text: "", signature: nil)])
  }

  @Test func toContentBlocks_richContentWithTextOnly() {
    let content = MessageContent.richContent([
      .text("first"),
      .text("second"),
    ])
    let blocks = content.toContentBlocks()
    #expect(blocks == [
      .text(text: "first", signature: nil),
      .text(text: "second", signature: nil),
    ])
  }

  @Test func toContentBlocks_richContentWithImageOnly() {
    let content = MessageContent.richContent([
      .image(blobURI: "blob://sess/img.png", mimeType: "image/png"),
    ])
    let blocks = content.toContentBlocks()
    #expect(blocks == [
      .image(blobURI: "blob://sess/img.png", mimeType: "image/png"),
    ])
  }

  @Test func toContentBlocks_richContentWithMixedParts() {
    let content = MessageContent.richContent([
      .text("Who is this?"),
      .image(blobURI: "blob://sess/photo.jpg", mimeType: "image/jpeg"),
    ])
    let blocks = content.toContentBlocks()
    #expect(blocks.count == 2)
    #expect(blocks[0] == .text(text: "Who is this?", signature: nil))
    #expect(blocks[1] == .image(blobURI: "blob://sess/photo.jpg", mimeType: "image/jpeg"))
  }

  @Test func toContentBlocks_richContentEmptyParts() {
    let content = MessageContent.richContent([])
    let blocks = content.toContentBlocks()
    #expect(blocks.isEmpty)
  }
}
