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
    /// Host:port for the runner WebSocket server (e.g. `1.2.3.4:5531`).
    public var address: String

    public init(name: String, address: String) {
      self.name = name
      self.address = address
    }
  }

  public var llm: LLM?
  public var runners: [Runner]?
  public var databasePath: String?
  public var llmRequestLogDir: String?
  public var workspacePath: String?
  public var host: String?
  public var port: Int?

  public init(
    llm: LLM? = nil,
    runners: [Runner]? = nil,
    databasePath: String? = nil,
    llmRequestLogDir: String? = nil,
    workspacePath: String? = nil,
    host: String? = nil,
    port: Int? = nil,
  ) {
    self.llm = llm
    self.runners = runners
    self.databasePath = databasePath
    self.llmRequestLogDir = llmRequestLogDir
    self.workspacePath = workspacePath
    self.host = host
    self.port = port
  }

  enum CodingKeys: String, CodingKey {
    case llm
    case runners
    case databasePath
    case llmRequestLogDir = "llm_request_log_dir"
    case workspacePath
    case host
    case port
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
  ///
  /// If `workspacePath` is set, it is tilde-expanded and returned.
  /// Otherwise falls back to `<dataRoot>/workspace` where `dataRoot` is
  /// the parent directory of the database path.
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
