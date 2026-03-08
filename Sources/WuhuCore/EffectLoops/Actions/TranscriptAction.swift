import WuhuAPI

/// Actions for the transcript subsystem.
enum TranscriptAction: Sendable {
  case append(WuhuSessionEntry)
}
