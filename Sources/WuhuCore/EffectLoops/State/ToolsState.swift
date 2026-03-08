import PiAI

/// Tool call tracking — active calls, statuses, repetition detection.
///
/// Maps from `WuhuSessionLoopState.toolCallStatus` and pulls in
/// `ToolCallRepetitionTracker` which was previously baked into the loop.
struct ToolsState: Sendable, Equatable {
  var statuses: [String: ToolCallStatus]
  var repetitionTracker: ToolCallRepetitionTracker

  /// Guard token: tool call IDs currently being recovered (stale recovery in flight).
  var recoveringIDs: Set<String> = []

  static var empty: ToolsState {
    .init(statuses: [:], repetitionTracker: ToolCallRepetitionTracker())
  }
}
