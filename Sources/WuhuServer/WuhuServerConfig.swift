import Foundation
import Logging
import Yams

public struct WuhuServerConfig: Sendable, Hashable {
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

  /// Server-wide default per-session cost limit in hundredths-of-a-cent
  /// (internal unit). nil = no cost gating.
  ///
  /// In the YAML config file, set `default_cost_limit` in **dollars**
  /// (e.g. `10` or `2.50`). `load()` converts to this internal unit.
  /// Set to `0` in YAML to explicitly disable cost gating.
  public var defaultCostLimitCents: Int64?

  /// Minimum log level for stderr output. Defaults to `.info`.
  public var logLevel: Logger.Level

  /// OTLP endpoint for OpenTelemetry export (e.g. "http://localhost:4318").
  /// If nil, OTel tracing/logging is disabled (spans are no-op).
  public var otelEndpoint: String?

  /// Minimum log level for OTel log export. Defaults to `logLevel`.
  public var otelLogLevel: Logger.Level?

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
    logLevel: Logger.Level = .info,
    otelEndpoint: String? = nil,
    otelLogLevel: Logger.Level? = nil,
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
    self.logLevel = logLevel
    self.otelEndpoint = otelEndpoint
    self.otelLogLevel = otelLogLevel
  }

  /// Hard-coded fallback: $10 per session (100,000 hundredths-of-a-cent).
  /// Applied when the YAML key is absent. Set `default_cost_limit: 0`
  /// in the config file to explicitly disable cost gating.
  public static let fallbackCostLimitCents: Int64 = 100_000

  public static func load(path: String) throws -> WuhuServerConfig {
    let expanded = (path as NSString).expandingTildeInPath
    let text = try String(contentsOfFile: expanded, encoding: .utf8)
    let raw = try YAMLDecoder().decode(RawYAML.self, from: text)

    var config = WuhuServerConfig(
      llm: raw.llm,
      databasePath: raw.databasePath,
      llmRequestLogDir: raw.llmRequestLogDir,
      workspacePath: raw.workspacePath,
      host: raw.host,
      port: raw.port,
      braveSearchAPIKey: raw.braveSearchAPIKey,
      runners: raw.runners,
      localRunnerSocket: raw.localRunnerSocket,
      logLevel: parseLogLevel(raw.logLevel) ?? .info,
      otelEndpoint: raw.otelEndpoint,
      otelLogLevel: parseLogLevel(raw.otelLogLevel),
    )

    // Convert dollars → hundredths-of-a-cent, apply fallback.
    if let dollars = raw.defaultCostLimit {
      let cents = Int64((dollars * 10000).rounded())
      // Explicit 0 means "disable cost gating" → nil.
      config.defaultCostLimitCents = cents == 0 ? nil : cents
    } else {
      // Key absent → apply safety-net fallback.
      config.defaultCostLimitCents = fallbackCostLimitCents
    }

    return config
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

// MARK: - Log level parsing

private func parseLogLevel(_ string: String?) -> Logger.Level? {
  guard let string, !string.isEmpty else { return nil }
  switch string.lowercased() {
  case "trace": return .trace
  case "debug": return .debug
  case "info": return .info
  case "notice": return .notice
  case "warning": return .warning
  case "error": return .error
  case "critical": return .critical
  default: return nil
  }
}

// MARK: - Raw YAML representation

/// Intermediate Codable type matching the YAML key names.
/// `WuhuServerConfig` is not itself Codable — it uses dollars in YAML
/// but hundredths-of-a-cent in memory, so the mapping is manual.
private struct RawYAML: Codable {
  var llm: WuhuServerConfig.LLM?
  var databasePath: String?
  var llmRequestLogDir: String?
  var workspacePath: String?
  var host: String?
  var port: Int?
  var braveSearchAPIKey: String?
  var runners: [WuhuServerConfig.Runner]?
  var localRunnerSocket: String?
  /// Cost limit in dollars (e.g. 10, 2.50). 0 = disable.
  var defaultCostLimit: Double?
  /// Log level string (e.g. "debug", "info"). Defaults to "info".
  var logLevel: String?
  /// OTLP endpoint (e.g. "http://localhost:4318"). nil = disabled.
  var otelEndpoint: String?
  /// OTel log level string. Defaults to logLevel value.
  var otelLogLevel: String?

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
    case defaultCostLimit = "default_cost_limit"
    case logLevel = "log_level"
    case otelEndpoint = "otel_endpoint"
    case otelLogLevel = "otel_log_level"
  }
}
