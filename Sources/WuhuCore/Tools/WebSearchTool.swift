import AsyncHTTPClient
import Foundation
import NIOFoundationCompat

/// Brave Search API web search tool.
///
/// Makes real HTTP requests to the Brave Search API using `AsyncHTTPClient` directly.
extension AgentTools {
  static func webSearchTool(apiKey: String, httpClient: AsyncHTTPClient.HTTPClient? = nil) -> AnyAgentTool {
    struct Params: Sendable {
      var query: String
      var count: Int?
      var offset: Int?
      var freshness: String?
      var country: String?

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let query = try a.requireString("query")
        let count = try a.optionalInt("count")
        let offset = try a.optionalInt("offset")
        let freshness = try a.optionalString("freshness")
        let country = try a.optionalString("country")
        return .init(query: query, count: count, offset: offset, freshness: freshness, country: country)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "query": .object([
          "type": .string("string"),
          "description": .string("Search query string"),
        ]),
        "count": .object([
          "type": .string("integer"),
          "minimum": .number(1),
          "maximum": .number(20),
          "description": .string("Number of results to return (default: 5, max: 20)"),
        ]),
        "offset": .object([
          "type": .string("integer"),
          "minimum": .number(0),
          "description": .string("Pagination offset (default: 0)"),
        ]),
        "freshness": .object([
          "type": .string("string"),
          "enum": .array([.string("pd"), .string("pw"), .string("pm"), .string("py")]),
          "description": .string("Filter by recency: pd (past day), pw (past week), pm (past month), py (past year)"),
        ]),
        "country": .object([
          "type": .string("string"),
          "description": .string("Country code for search locale, e.g. 'US', 'GB', 'DE'"),
        ]),
      ]),
      "required": .array([.string("query")]),
      "additionalProperties": .bool(false),
    ])

    let description = [
      "Search the web using Brave Search.",
      "Returns titles, URLs, and descriptions for matching web pages.",
      "Use this to find current information, documentation, references, or anything not in your training data.",
    ].joined(separator: "\n")

    let tool = Tool(name: "web_search", description: description, parameters: schema)

    // Use a dedicated client with gzip decompression enabled. The singleton
    // HTTPClient.shared doesn't auto-decompress, so we create our own with
    // the shared event loop group to avoid spinning up extra threads.
    let client = httpClient ?? webSearchHTTPClient

    return AnyAgentTool(tool: tool, label: "web_search") { _, args in
      let params = try Params.parse(toolName: tool.name, args: args)
      let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else {
        throw WebSearchError.message("query must not be empty")
      }

      let count = min(max(params.count ?? 5, 1), 20)

      // Build URL
      var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
      var queryItems: [URLQueryItem] = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "count", value: String(count)),
      ]
      if let offset = params.offset {
        queryItems.append(URLQueryItem(name: "offset", value: String(offset)))
      }
      if let freshness = params.freshness {
        queryItems.append(URLQueryItem(name: "freshness", value: freshness))
      }
      if let country = params.country {
        queryItems.append(URLQueryItem(name: "country", value: country))
      }
      components.queryItems = queryItems

      guard let url = components.url else {
        throw WebSearchError.message("Failed to construct search URL")
      }

      var request = HTTPClientRequest(url: url.absoluteString)
      request.method = .GET
      request.headers.add(name: "Accept", value: "application/json")
      request.headers.add(name: "Accept-Encoding", value: "gzip")
      request.headers.add(name: "X-Subscription-Token", value: apiKey)

      let response = try await client.execute(request, timeout: .seconds(30))

      let statusCode = Int(response.status.code)
      guard statusCode >= 200, statusCode < 300 else {
        let body = try await String(buffer: response.body.collect(upTo: 1024 * 64))
        throw WebSearchError.message("Brave Search API returned HTTP \(statusCode): \(body.prefix(500))")
      }

      let data = try await Data(buffer: response.body.collect(upTo: 1024 * 1024))

      // Parse JSON response
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WebSearchError.message("Failed to parse Brave Search response")
      }

      // Extract web results
      let webResults = (json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []

      if webResults.isEmpty {
        return AgentToolResult(
          content: [.text("No results found for: \(query)")],
          details: .object(["query": .string(query), "resultCount": .number(0)]),
        )
      }

      // Format results for the agent
      var outputLines: [String] = []
      var detailResults: [JSONValue] = []

      for (idx, result) in webResults.prefix(count).enumerated() {
        let title = result["title"] as? String ?? "(no title)"
        let resultURL = result["url"] as? String ?? ""
        let description = result["description"] as? String ?? ""

        outputLines.append("[\(idx + 1)] \(title)")
        outputLines.append("    URL: \(resultURL)")
        if !description.isEmpty {
          outputLines.append("    \(description)")
        }
        outputLines.append("")

        detailResults.append(.object([
          "title": .string(title),
          "url": .string(resultURL),
          "description": .string(description),
        ]))
      }

      let output = outputLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

      return AgentToolResult(
        content: [.text(output)],
        details: .object([
          "query": .string(query),
          "resultCount": .number(Double(detailResults.count)),
          "results": .array(detailResults),
        ]),
      )
    }
  }
}

/// Module-level HTTP client with automatic gzip/deflate decompression enabled.
/// Uses the shared event loop group (singleton) so no extra threads are created.
/// This is never explicitly shut down — it lives for the process lifetime, which
/// is fine for a long-running server.
private let webSearchHTTPClient: AsyncHTTPClient.HTTPClient = {
  var config = AsyncHTTPClient.HTTPClient.Configuration()
  config.decompression = .enabled(limit: .ratio(10))
  return AsyncHTTPClient.HTTPClient(
    eventLoopGroupProvider: .singleton,
    configuration: config,
  )
}()

private enum WebSearchError: Error, Sendable, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(m): m
    }
  }
}
