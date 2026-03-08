import WuhuAPI

/// Transcript entries — the session conversation log.
///
/// Maps from `WuhuSessionLoopState.entries`.
struct TranscriptState: Sendable, Equatable {
  var entries: [WuhuSessionEntry]

  static var empty: TranscriptState {
    .init(entries: [])
  }
}
