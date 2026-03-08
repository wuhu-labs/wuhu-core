/// Actions for the execution status subsystem.
enum StatusAction: Sendable {
  case updated(SessionStatusSnapshot)
}
