/// Tracks consecutive identical tool calls to detect degenerate loops.
///
/// Each unique `(toolName, argsHash)` pair is tracked independently.
/// After a tool call completes, call ``record(toolName:argsHash:resultHash:)``
/// to update the streak for that slot. If the result hash matches the
/// previous result for the same slot, the counter increments; otherwise
/// it resets to 1.
///
/// Before executing a tool call, query
/// ``preflightCount(toolName:argsHash:)`` to decide whether to warn or
/// block.
///
/// - At count ≥ ``warningThreshold`` (3): callers should append a warning.
/// - At count ≥ ``blockThreshold`` (5): callers should block execution.
///
/// Call ``reset()`` when a user message arrives (interrupt/steer).
struct ToolCallRepetitionTracker: Sendable, Equatable {
  // MARK: - Thresholds

  static let warningThreshold = 3
  static let blockThreshold = 5

  // MARK: - Per-slot state

  private struct SlotKey: Hashable, Sendable {
    var toolName: String
    var argsHash: Int
  }

  private struct SlotState: Sendable, Equatable {
    var lastResultHash: Int
    var consecutiveCount: Int
  }

  private var slots: [SlotKey: SlotState] = [:]

  // MARK: - API

  /// The current consecutive count for a `(toolName, argsHash)` pair.
  ///
  /// Returns 0 if the pair has never been seen. Use this before execution
  /// to decide whether to block (count ≥ ``blockThreshold``).
  func preflightCount(toolName: String, argsHash: Int) -> Int {
    let key = SlotKey(toolName: toolName, argsHash: argsHash)
    return slots[key]?.consecutiveCount ?? 0
  }

  /// Record a completed tool call. Returns the new consecutive count.
  ///
  /// If the result hash matches the previous result for the same
  /// `(toolName, argsHash)` slot, the counter increments. Otherwise
  /// it resets to 1.
  @discardableResult
  mutating func record(toolName: String, argsHash: Int, resultHash: Int) -> Int {
    let key = SlotKey(toolName: toolName, argsHash: argsHash)
    if let existing = slots[key], existing.lastResultHash == resultHash {
      slots[key]!.consecutiveCount += 1
    } else {
      slots[key] = SlotState(lastResultHash: resultHash, consecutiveCount: 1)
    }
    return slots[key]!.consecutiveCount
  }

  /// Reset all tracking state (e.g., when a user message arrives).
  mutating func reset() {
    slots.removeAll()
  }

  /// Warning text appended to tool results at the warning threshold.
  static let warningText =
    "\n\n[Warning: This tool has returned the same result \(warningThreshold) consecutive times. Consider doing something else or waiting for an external event.]"

  /// Error text returned when a tool call is blocked.
  static let blockText =
    "[Error: Blocked — this tool has been called \(blockThreshold) consecutive times with identical arguments and results. The loop has been broken to prevent waste. Take a different action.]"
}
