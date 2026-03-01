import Foundation
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
}
