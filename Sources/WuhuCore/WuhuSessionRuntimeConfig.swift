import Foundation
import PiAI

actor WuhuSessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []

  func setTools(_ tools: [AnyAgentTool]) {
    _tools = tools
  }

  func tools() -> [AnyAgentTool] {
    _tools
  }
}
