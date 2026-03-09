import Foundation
import Yams

public struct WuhuServerConfig: Sendable, Hashable, Codable {
  public struct LLM: Sendable, Hashable, Codable {
    public var openai: String?
    public var anthropic: String?

    public init(openai: String? = nil, anthropic: String? = nil) {
      self.openai = openai
      self.anthropic = anthropic
    }
  }

  public struct Runner: Sendable, Hashable, Codable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
      self.name = name
      self.address = address
    }
  }

  public var llm: LLM?
  public var databasePath: String?
  public var llmRequestLogDir: String?
  public var workspacePath: String?
  public var host: String?
  public var port: Int?
  public var braveSearchAPIKey: String?
  public var runners: [Runner]?
  /// Unix domain socket path for the local runner. If nil, a random
  /// temporary path is used.
  public var localRunnerSocket: String?
  /// Server-wide default per-session cost limit in hundredths-of-a-cent.
  /// $10 = 100,000. NULL disables cost gating.
  public var defaultCostLimitCents: Int64?

  public init(
    llm: LLM? = nil,
    databasePath: String? = nil,
    llmRequestLogDir: String? = nil,
    workspacePath: String? = nil,
    host: String? = nil,
    port: Int? = nil,
    braveSearchAPIKey: String? = nil,
    runners: [Runner]? = nil,
    localRunnerSocket: String? = nil,
    defaultCostLimitCents: Int64? = 100_000,
  ) {
    self.llm = llm
    self.databasePath = databasePath
    self.llmRequestLogDir = llmRequestLogDir
    self.workspacePath = workspacePath
    self.host = host
    self.port = port
    self.braveSearchAPIKey = braveSearchAPIKey
    self.runners = runners
    self.localRunnerSocket = localRunnerSocket
    self.defaultCostLimitCents = defaultCostLimitCents
  }

  enum CodingKeys: String, CodingKey {
    case llm
    case databasePath
    case llmRequestLogDir = "llm_request_log_dir"
    case workspacePath
    case host
    case port
    case braveSearchAPIKey = "brave_search_api_key"
    case runners
    case localRunnerSocket = "local_runner_socket"
    case defaultCostLimitCents = "default_cost_limit_cents"
  }

  public static func load(path: String) throws -> WuhuServerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    return try YAMLDecoder().decode(WuhuServerConfig.self, from: text)
  }

  public static func defaultPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".wuhu/server.yml")
      .path
  }

  /// Resolves the workspace root directory from this config.
  public func resolveWorkspaceRoot(databasePath: String) -> String {
    if let wp = workspacePath, !wp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return (wp as NSString).expandingTildeInPath
    }
    return URL(fileURLWithPath: databasePath, isDirectory: false)
      .deletingLastPathComponent()
      .appendingPathComponent("workspace", isDirectory: true)
      .path
  }
}
