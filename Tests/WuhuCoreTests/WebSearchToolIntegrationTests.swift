import Foundation
import Testing
import WuhuCore

/// Integration tests for web_search tool — hits the real Brave Search API.
/// These require the BRAVE_SEARCH_API_KEY environment variable to be set.
/// Skipped automatically when the key is absent.
struct WebSearchToolIntegrationTests {
  private let apiKey: String? = ProcessInfo.processInfo.environment["BRAVE_SEARCH_API_KEY"]

  private func webSearchTool() throws -> AnyAgentTool {
    guard let apiKey, !apiKey.isEmpty else {
      throw SkipError()
    }
    let tools = WuhuTools.codingAgentTools(
      cwdProvider: { "/tmp" },
      braveSearchAPIKey: apiKey,
    )
    guard let tool = tools.first(where: { $0.tool.name == "web_search" }) else {
      throw SkipError()
    }
    return tool
  }

  private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  @Test func basicSearchReturnsResults() async throws {
    let t = try webSearchTool()
    let result = try await t.execute(
      toolCallId: "ws1",
      args: .object([
        "query": .string("Swift programming language"),
        "count": .number(3),
      ]),
    )
    let text = textOutput(result)
    #expect(text.contains("Swift"))
    #expect(text.contains("URL:"))
    #expect((result.details.object?["resultCount"]?.doubleValue ?? 0) > 0)
  }

  @Test func emptyQueryThrows() async throws {
    let t = try webSearchTool()
    await #expect(throws: Error.self) {
      _ = try await t.execute(
        toolCallId: "ws2",
        args: .object(["query": .string("   ")]),
      )
    }
  }

  @Test func countParameterLimitsResults() async throws {
    let t = try webSearchTool()
    let result = try await t.execute(
      toolCallId: "ws3",
      args: .object([
        "query": .string("Rust programming language"),
        "count": .number(2),
      ]),
    )
    let count = result.details.object?["resultCount"]?.doubleValue ?? 0
    #expect(count <= 2)
    #expect(count > 0)
  }

  @Test func freshnessParameterWorks() async throws {
    let t = try webSearchTool()
    let result = try await t.execute(
      toolCallId: "ws4",
      args: .object([
        "query": .string("latest tech news"),
        "count": .number(3),
        "freshness": .string("pw"),
      ]),
    )
    let text = textOutput(result)
    #expect(!text.isEmpty)
  }

  @Test func toolNotRegisteredWithoutKey() {
    let tools = WuhuTools.codingAgentTools(
      cwdProvider: { "/tmp" },
      braveSearchAPIKey: nil,
    )
    #expect(tools.first(where: { $0.tool.name == "web_search" }) == nil)
  }

  @Test func toolNotRegisteredWithEmptyKey() {
    let tools = WuhuTools.codingAgentTools(
      cwdProvider: { "/tmp" },
      braveSearchAPIKey: "",
    )
    #expect(tools.first(where: { $0.tool.name == "web_search" }) == nil)
  }

  /// Marker error to skip tests when no API key is available.
  private struct SkipError: Error {}
}
