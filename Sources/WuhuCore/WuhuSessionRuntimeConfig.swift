import Foundation
import WuhuAI

typealias WuhuSessionToolProvider = @Sendable (WuhuSessionLoopState) async -> [AnyAgentTool]

actor WuhuSessionRuntimeConfig {
  private var toolProvider: WuhuSessionToolProvider = { _ in [] }

  func setToolProvider(_ provider: @escaping WuhuSessionToolProvider) {
    toolProvider = provider
  }

  func tools(for state: WuhuSessionLoopState) async -> [AnyAgentTool] {
    await toolProvider(state)
  }
}
