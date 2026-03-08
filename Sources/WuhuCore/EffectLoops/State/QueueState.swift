/// Queue state — system urgent, steer, and follow-up queues.
///
/// Maps from `WuhuSessionLoopState.systemUrgent`, `.steer`, `.followUp`.
struct QueueState: Sendable, Equatable {
  var system: SystemUrgentQueueBackfill
  var steer: UserQueueBackfill
  var followUp: UserQueueBackfill

  static var empty: QueueState {
    .init(
      system: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      steer: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
      followUp: .init(cursor: .init(rawValue: "0"), pending: [], journal: []),
    )
  }
}
