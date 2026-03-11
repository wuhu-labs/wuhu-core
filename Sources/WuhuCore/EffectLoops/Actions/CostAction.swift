/// Actions for the cost subsystem — budget limit management.
///
/// All monetary values are in **hundredths-of-a-cent** (Int64).
enum CostAction: Sendable {
  case limitUpdated(Int64)
  case limitCleared
}
