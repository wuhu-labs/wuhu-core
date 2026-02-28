import Foundation
import Testing
import WuhuCore

struct ReadToolImageTests {
  private func tools(cwd: String) -> [String: AnyAgentTool] {
    Dictionary(uniqueKeysWithValues: WuhuTools.codingAgentTools(cwd: cwd).map { ($0.tool.name, $0) })
  }

  private func makeTempDir() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-read-img-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  @Test func readToolReturnsImageContentForPNG() async throws {
    let dir = try makeTempDir()
    let file = (dir as NSString).appendingPathComponent("screenshot.png")
    // Write a small fake PNG-like binary payload.
    let content = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    try content.write(to: URL(fileURLWithPath: file))

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t1", args: .object(["path": .string("screenshot.png")]))

    // Should have exactly one image content block.
    #expect(result.content.count == 1)
    guard case let .image(img) = result.content.first else {
      Issue.record("Expected image content block, got: \(result.content)")
      return
    }
    #expect(img.mimeType == "image/png")
    // Verify the data is base64.
    let decoded = Data(base64Encoded: img.data)
    #expect(decoded == content)

    // Details should indicate type=image.
    #expect(result.details.object?["type"]?.stringValue == "image")
    #expect(result.details.object?["mimeType"]?.stringValue == "image/png")
  }

  @Test func readToolReturnsImageContentForJPG() async throws {
    let dir = try makeTempDir()
    let file = (dir as NSString).appendingPathComponent("photo.jpg")
    let content = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
    try content.write(to: URL(fileURLWithPath: file))

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t2", args: .object(["path": .string("photo.jpg")]))

    #expect(result.content.count == 1)
    guard case let .image(img) = result.content.first else {
      Issue.record("Expected image content block")
      return
    }
    #expect(img.mimeType == "image/jpeg")
  }

  @Test func readToolReturnsTextForNonImage() async throws {
    let dir = try makeTempDir()
    let file = (dir as NSString).appendingPathComponent("hello.txt")
    try "Hello, world!".write(toFile: file, atomically: true, encoding: .utf8)

    let t = try #require(tools(cwd: dir)["read"])
    let result = try await t.execute(toolCallId: "t3", args: .object(["path": .string("hello.txt")]))

    guard case let .text(t) = result.content.first else {
      Issue.record("Expected text content block")
      return
    }
    #expect(t.text == "Hello, world!")
  }

  @Test func readToolDescriptionMentionsImages() throws {
    let dir = try makeTempDir()
    let t = try #require(tools(cwd: dir)["read"])
    #expect(t.tool.description.contains("image") || t.tool.description.contains("Image"))
  }
}
