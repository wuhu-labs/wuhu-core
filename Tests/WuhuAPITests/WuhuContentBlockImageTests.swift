import Foundation
import Testing
import WuhuAPI

struct WuhuContentBlockImageTests {
  @Test func imageCodableRoundTrip() throws {
    let block = WuhuContentBlock.image(blobURI: "blob://sess-1/sha256-abc123.png", mimeType: "image/png")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(block)
    let decoded = try JSONDecoder().decode(WuhuContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func imageEncodeProducesCorrectJSON() throws {
    let block = WuhuContentBlock.image(blobURI: "blob://sess-1/sha256-abc.jpg", mimeType: "image/jpeg")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(block)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["type"] as? String == "image")
    #expect(json["blobURI"] as? String == "blob://sess-1/sha256-abc.jpg")
    #expect(json["mimeType"] as? String == "image/jpeg")
  }

  @Test func imageDecodeFromJSON() throws {
    let json: [String: Any] = [
      "type": "image",
      "blobURI": "blob://sess-2/sha256-xyz.gif",
      "mimeType": "image/gif",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let block = try JSONDecoder().decode(WuhuContentBlock.self, from: data)
    #expect(block == .image(blobURI: "blob://sess-2/sha256-xyz.gif", mimeType: "image/gif"))
  }

  @Test func textCodableStillWorks() throws {
    let block = WuhuContentBlock.text(text: "hello", signature: nil)
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(WuhuContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func toolCallCodableStillWorks() throws {
    let block = WuhuContentBlock.toolCall(id: "t1", name: "bash", arguments: .object(["cmd": .string("ls")]))
    let data = try JSONEncoder().encode(block)
    let decoded = try JSONDecoder().decode(WuhuContentBlock.self, from: data)
    #expect(decoded == block)
  }

  @Test func toolResultMessageWithImageRoundTrips() throws {
    let msg = WuhuToolResultMessage(
      toolCallId: "t1",
      toolName: "read",
      content: [
        .text(text: "Image loaded", signature: nil),
        .image(blobURI: "blob://sess-1/sha256-abc.png", mimeType: "image/png"),
      ],
      details: .object([:]),
      isError: false,
      timestamp: Date(timeIntervalSince1970: 1_000_000),
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(msg)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let decoded = try decoder.decode(WuhuToolResultMessage.self, from: data)
    #expect(decoded == msg)
  }
}
