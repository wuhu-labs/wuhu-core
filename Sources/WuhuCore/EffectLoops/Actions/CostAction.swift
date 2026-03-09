/// Actions for the cost subsystem — budget tracking and pause gating.
///
/// All monetary values are in **hundredths-of-a-cent** (Int64).
enum CostAction: Sendable {
  case spent(Int64)
  case approved(Int64)
  case limitUpdated(Int64)
  case limitCleared
  case pause
  case resume
}
