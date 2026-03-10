import Foundation
import PiAI

actor SessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []
  let defaultCostLimitCents: Int64?

  init(defaultCostLimitCents: Int64? = nil) {
    self.defaultCostLimitCents = defaultCostLimitCents
  }

  func setTools(_ tools: [AnyAgentTool]) {
    _tools = tools
  }

  func tools() -> [AnyAgentTool] {
    _tools
  }
}
