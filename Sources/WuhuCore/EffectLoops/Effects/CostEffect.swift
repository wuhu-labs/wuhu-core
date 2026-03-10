import Foundation
import WuhuAPI

/// Effect factory for cost-related side effects.
extension AgentBehavior {
  /// Persists a `wuhu_cost_limit_exceeded_v1` custom entry to the transcript
  /// so the user sees why the session stopped.
  func emitCostExceededEntry(state: AgentState) -> Effect<AgentAction> {
    let sessionID = sessionID
    let store = store
    let totalSpent = state.cost.totalSpent
    let budgetRemaining = state.cost.budgetRemaining
    return Effect { send in
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

      do {
        let (_, entry) = try await store.appendEntryWithSession(
          sessionID: sessionID,
          payload: payload,
          createdAt: Date(),
        )
        await send(AgentAction.transcript(.append(entry)))
      } catch {
        let line = "[AgentBehavior] ERROR: failed to emit cost-exceeded entry: \(String(describing: error))\n"
        FileHandle.standardError.write(Data(line.utf8))
      }
    }
  }
}
