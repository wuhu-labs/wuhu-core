/// Actions for the queue subsystem — system, steer, follow-up queues.
enum QueueAction: Sendable {
  case systemUpdated(SystemUrgentQueueBackfill)
  case steerUpdated(UserQueueBackfill)
  case followUpUpdated(UserQueueBackfill)
}
