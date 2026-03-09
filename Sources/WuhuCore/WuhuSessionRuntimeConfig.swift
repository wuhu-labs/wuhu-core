import Foundation
import PiAI

actor WuhuSessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []
  private var _streamFn: StreamFn = PiAI.streamSimple
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

  func setStreamFn(_ streamFn: @escaping StreamFn) {
    _streamFn = streamFn
  }

  func streamFn() -> StreamFn {
    _streamFn
  }
}
