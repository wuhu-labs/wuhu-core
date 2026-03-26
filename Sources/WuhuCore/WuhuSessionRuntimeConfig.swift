import Foundation
import WuhuAI

typealias WuhuSessionToolProvider = @Sendable (WuhuSessionLoopState) async -> [AnyAgentTool]

actor WuhuSessionRuntimeConfig {
  private let braveSearchAPIKey: String?
  private var toolProvider: WuhuSessionToolProvider = { _ in [] }

  init(braveSearchAPIKey: String? = nil) {
    self.braveSearchAPIKey = braveSearchAPIKey
  }

  func setToolProvider(_ provider: @escaping WuhuSessionToolProvider) {
    toolProvider = provider
  }

  func tools(for state: WuhuSessionLoopState) async -> [AnyAgentTool] {
    await toolProvider(state)
  }

  func codingToolContext() -> String? {
    braveSearchAPIKey
  }
}
