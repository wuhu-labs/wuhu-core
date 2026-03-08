/// Execution status state — running, idle, stopped.
///
/// Maps directly from `WuhuSessionLoopState.status`.
struct StatusState: Sendable, Equatable {
  var snapshot: SessionStatusSnapshot

  static var empty: StatusState {
    .init(snapshot: .init(status: .idle))
  }
}
