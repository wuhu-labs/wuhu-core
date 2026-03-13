import Foundation
import PiAI

actor WuhuSessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []
  private var _streamFnOverride: StreamFn?

  func setTools(_ tools: [AnyAgentTool]) {
    _tools = tools
  }

  func tools() -> [AnyAgentTool] {
    _tools
  }

  func setStreamFn(_ streamFn: @escaping StreamFn) {
    _streamFnOverride = streamFn
  }

  func streamFn() -> StreamFn? {
    _streamFnOverride
  }
}
