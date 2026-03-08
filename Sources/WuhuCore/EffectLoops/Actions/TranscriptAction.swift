import WuhuAPI

/// Actions for the transcript subsystem.
enum TranscriptAction: Sendable {
  case append(WuhuSessionEntry)
  /// Clears the compacting guard token when a compaction effect completes.
  case compactionFinished
}
