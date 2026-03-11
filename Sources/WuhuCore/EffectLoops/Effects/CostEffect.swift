import Foundation
import WuhuAPI

/// Effect factory for cost-related side effects.
extension AgentBehavior {
  /// Persists a `wuhu_cost_limit_exceeded_v1` custom entry to the transcript
  /// so the user sees why the session paused.
  func emitCostExceededEntry() -> AgentEffect {
    let sessionID = sessionID
    let store = store

    return .sync { state in
      let totalSpent = state.cost.totalSpent
      let budgetRemaining = state.cost.budgetRemaining

      let custom = WuhuCustomMessage(
        customType: WuhuCustomMessageTypes.costLimitExceeded,
        content: [.text(text: "Session paused: cost limit exceeded.", signature: nil)],
        details: .object([
          "totalSpentHundredths": .number(Double(totalSpent)),
          "budgetRemainingHundredths": budgetRemaining.map { .number(Double($0)) } ?? .null,
        ]),
        display: true,
        timestamp: Date(),
      )
      let payload: WuhuEntryPayload = .message(.customMessage(custom))

      let (_, entry) = try await store.appendEntryWithSession(
        sessionID: sessionID,
        payload: payload,
        createdAt: Date(),
      )

      return [.transcript(.append(entry))]
    }
  }
}
