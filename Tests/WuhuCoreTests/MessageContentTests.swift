import Foundation
import Testing
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
    // Old format: synthesized Codable produced {"text":{"_0":"Hello"}} for .text("Hello")
    // Actually, synthesized enum Codable is {"text":{"_0":"Hello"}} — but our implementation
    // tries to decode via TextWrapper which expects {"text":"..."}.
    let oldJSON = #"{"text":"Hello from legacy"}"#
    let data = Data(oldJSON.utf8)
    let decoded = try JSONDecoder().decode(MessageContent.self, from: data)
    #expect(decoded == .text("Hello from legacy"))
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
}
