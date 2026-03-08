import WuhuAPI

/// Transcript entries — the session conversation log.
///
/// Maps from `WuhuSessionLoopState.entries`.
struct TranscriptState: Sendable, Equatable {
  var entries: [WuhuSessionEntry]

  /// Guard token: set before returning a compaction effect to prevent re-scheduling.
  var isCompacting: Bool = false

  static var empty: TranscriptState {
    .init(entries: [])
  }
}
