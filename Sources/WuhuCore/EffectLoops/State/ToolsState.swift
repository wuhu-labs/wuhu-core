import Foundation
import PiAI

/// A tool call's status plus the timestamp when it was last updated.
/// Used for stale detection — tool calls are only considered stale
/// after a deadline has passed since they were started.
struct ToolCallRecord: Sendable, Equatable {
  var status: ToolCallStatus
  var updatedAt: Date

  init(status: ToolCallStatus, updatedAt: Date = Date()) {
    self.status = status
    self.updatedAt = updatedAt
  }
}

/// Tool call tracking — active calls, statuses, repetition detection.
///
/// Maps from `WuhuSessionLoopState.toolCallStatus` and pulls in
/// `ToolCallRepetitionTracker` which was previously baked into the loop.
struct ToolsState: Sendable, Equatable {
  var statuses: [String: ToolCallRecord]
  var repetitionTracker: ToolCallRepetitionTracker

  /// Guard token: tool call IDs currently being recovered (stale recovery in flight).
  var recoveringIDs: Set<String> = []

  /// Guard token: tool call IDs currently being executed (prevents false stale detection).
  var executingIDs: Set<String> = []

  /// Bash results delivered from the worker that need to be persisted to the transcript.
  /// Keyed by tool call ID.
  var pendingBashResults: [String: BashResult] = [:]

  static var empty: ToolsState {
    .init(statuses: [:], repetitionTracker: ToolCallRepetitionTracker())
  }
}
