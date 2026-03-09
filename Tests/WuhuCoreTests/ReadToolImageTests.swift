import Dependencies
import Foundation
import Testing
import WuhuCore

struct ReadToolImageTests {
  private let cwd = "/workspace"

  private func makeIO() -> InMemoryFileIO {
    let io = InMemoryFileIO()
    io.seedDirectory(path: cwd)
    return io
  }

  private func tools() -> [String: AnyAgentTool] {
    let resolver = WuhuTools.testMountResolver(cwd: cwd)
    return Dictionary(uniqueKeysWithValues: WuhuTools.codingAgentTools(cwdProvider: { cwd }, mountResolver: resolver).map { ($0.tool.name, $0) })
  }

  @Test func readToolReturnsImageContentForPNG() async throws {
    let io = makeIO()
    let content = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    io.seedFile(path: "\(cwd)/screenshot.png", data: content)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let execResult = try await t.execute(toolCallId: "t1", args: .object(["path": .string("screenshot.png")]))
      guard case let .immediate(result) = execResult else {
        Issue.record("Expected immediate result"); return
      }

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
  }

  @Test func readToolReturnsImageContentForJPG() async throws {
    let io = makeIO()
    let content = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
    io.seedFile(path: "\(cwd)/photo.jpg", data: content)

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let execResult = try await t.execute(toolCallId: "t2", args: .object(["path": .string("photo.jpg")]))
      guard case let .immediate(result) = execResult else {
        Issue.record("Expected immediate result"); return
      }

      #expect(result.content.count == 1)
      guard case let .image(img) = result.content.first else {
        Issue.record("Expected image content block")
        return
      }
      #expect(img.mimeType == "image/jpeg")
    }
  }

  @Test func readToolReturnsTextForNonImage() async throws {
    let io = makeIO()
    io.seedFile(path: "\(cwd)/hello.txt", content: "Hello, world!")

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      let execResult = try await t.execute(toolCallId: "t3", args: .object(["path": .string("hello.txt")]))
      guard case let .immediate(result) = execResult else {
        Issue.record("Expected immediate result"); return
      }

      guard case let .text(t) = result.content.first else {
        Issue.record("Expected text content block")
        return
      }
      #expect(t.text == "Hello, world!")
    }
  }

  @Test func readToolDescriptionMentionsImages() throws {
    let io = makeIO()
    try withDependencies {
      $0.fileIO = io
    } operation: {
      let t = try #require(tools()["read"])
      #expect(t.tool.description.contains("image") || t.tool.description.contains("Image"))
    }
  }
}
