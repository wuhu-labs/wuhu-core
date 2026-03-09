/// Actions for the cost subsystem — budget tracking and pause gating.
enum CostAction: Sendable {
  case spent(Int)
  case approved(Int)
  case pause
  case resume
}
