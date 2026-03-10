import Foundation
import Logging
import Testing
import WuhuServer

struct WuhuServerConfigTests {
  @Test func loadsYAML() throws {
    let yaml = """
    llm:
      openai: sk-openai
      anthropic: sk-anthropic
    llm_request_log_dir: /tmp/wuhu-llm-logs
    databasePath: /tmp/wuhu.sqlite
    host: 127.0.0.1
    port: 5530
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    #expect(config.llm?.openai == "sk-openai")
    #expect(config.llm?.anthropic == "sk-anthropic")
    #expect(config.databasePath == "/tmp/wuhu.sqlite")
    #expect(config.llmRequestLogDir == "/tmp/wuhu-llm-logs")
    #expect(config.host == "127.0.0.1")
    #expect(config.port == 5530)
  }

  @Test func loadsWorkspacePath() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    workspacePath: /custom/workspace
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    #expect(config.workspacePath == "/custom/workspace")
  }

  @Test func resolveWorkspaceRootUsesConfigWhenSet() {
    let config = WuhuServerConfig(workspacePath: "/my/workspace")
    let resolved = config.resolveWorkspaceRoot(databasePath: "/data/wuhu.sqlite")
    #expect(resolved == "/my/workspace")
  }

  @Test func resolveWorkspaceRootFallsBackToDataRoot() {
    let config = WuhuServerConfig()
    let resolved = config.resolveWorkspaceRoot(databasePath: "/data/wuhu.sqlite")
    #expect(resolved.hasSuffix("/data/workspace"))
  }

  @Test func costLimitFallbackAppliedWhenMissing() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    // Key absent → $10 fallback (100,000 hundredths-of-a-cent)
    #expect(config.defaultCostLimitCents == WuhuServerConfig.fallbackCostLimitCents)
    #expect(config.defaultCostLimitCents == 100_000)
  }

  @Test func costLimitExplicitZeroDisablesGating() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    default_cost_limit: 0
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    // 0 means "disable cost gating" → nil
    #expect(config.defaultCostLimitCents == nil)
  }

  @Test func costLimitExplicitDollarValue() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    default_cost_limit: 50
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    // $50 = 500,000 hundredths-of-a-cent
    #expect(config.defaultCostLimitCents == 500_000)
  }

  @Test func costLimitFractionalDollars() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    default_cost_limit: 2.50
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    // $2.50 = 25,000 hundredths-of-a-cent
    #expect(config.defaultCostLimitCents == 25000)
  }

  @Test func loadsLogLevelAndOtelConfig() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    log_level: debug
    otel_endpoint: "http://localhost:4318"
    otel_log_level: trace
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    #expect(config.logLevel == .debug)
    #expect(config.otelEndpoint == "http://localhost:4318")
    #expect(config.otelLogLevel == .trace)
  }

  @Test func logLevelDefaultsToInfo() throws {
    let yaml = """
    databasePath: /tmp/wuhu.sqlite
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    #expect(config.logLevel == .info)
    #expect(config.otelEndpoint == nil)
    #expect(config.otelLogLevel == nil)
  }
}
