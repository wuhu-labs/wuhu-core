import Foundation
import PiAI

actor WuhuSessionRuntimeConfig {
  private var _tools: [AnyAgentTool] = []
  private var _streamFn: StreamFn = PiAI.streamSimple

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
