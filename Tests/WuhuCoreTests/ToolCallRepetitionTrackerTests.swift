import Foundation
import Testing
@testable import WuhuCore

struct ToolCallRepetitionTrackerTests {
  // MARK: - Basic counting

  @Test func identicalCallsIncrementCounter() {
    var tracker = ToolCallRepetitionTracker()

    let count1 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count1 == 1)

    let count2 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count2 == 2)

    let count3 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count3 == 3)

    let count4 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count4 == 4)

    let count5 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count5 == 5)
  }

  // MARK: - Warning at threshold 3

  @Test func warningAtThresholdThree() {
    var tracker = ToolCallRepetitionTracker()

    // First two calls — no warning
    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 1)

    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 2)

    // Third call should be at warning threshold
    let count3 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count3 == 3)
    #expect(count3 >= ToolCallRepetitionTracker.warningThreshold)
  }

  // MARK: - Block at threshold 5

  @Test func blockAtThresholdFive() {
    var tracker = ToolCallRepetitionTracker()

    // Build up to 4 identical calls
    for _ in 1 ... 4 {
      tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    }

    // Before the 5th call, preflight should indicate count 4
    let preflight = tracker.preflightCount(toolName: "list_files", argsHash: 42)
    #expect(preflight == 4)
    // The 5th call would make count 5, which hits the block threshold
    // In the agent loop, preflight >= blockThreshold means block
    #expect(preflight < ToolCallRepetitionTracker.blockThreshold)

    // Record the 5th call
    let count5 = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count5 == 5)
    #expect(count5 >= ToolCallRepetitionTracker.blockThreshold)

    // Now preflight for a 6th call should be >= blockThreshold → blocked
    let preflight6 = tracker.preflightCount(toolName: "list_files", argsHash: 42)
    #expect(preflight6 >= ToolCallRepetitionTracker.blockThreshold)
  }

  // MARK: - Counter resets when args change

  @Test func counterResetsWhenArgsChange() {
    var tracker = ToolCallRepetitionTracker()

    tracker.record(toolName: "read", argsHash: 10, resultHash: 100)
    tracker.record(toolName: "read", argsHash: 10, resultHash: 100)
    #expect(tracker.preflightCount(toolName: "read", argsHash: 10) == 2)

    // Same tool, different args → different slot, starts fresh
    let count = tracker.record(toolName: "read", argsHash: 20, resultHash: 200)
    #expect(count == 1)
    #expect(tracker.preflightCount(toolName: "read", argsHash: 20) == 1)

    // Original slot is still tracked separately
    #expect(tracker.preflightCount(toolName: "read", argsHash: 10) == 2)
  }

  // MARK: - Counter resets when result changes

  @Test func counterResetsWhenResultChanges() {
    var tracker = ToolCallRepetitionTracker()

    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 2)

    // Same tool+args, different result → counter resets for this slot
    let count = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 200)
    #expect(count == 1)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 1)
  }

  // MARK: - Different tools tracked independently

  @Test func differentToolsTrackedIndependently() {
    var tracker = ToolCallRepetitionTracker()

    tracker.record(toolName: "list_files", argsHash: 1, resultHash: 10)
    tracker.record(toolName: "list_files", argsHash: 1, resultHash: 10)
    tracker.record(toolName: "list_files", argsHash: 1, resultHash: 10)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 1) == 3)

    // Different tool doesn't affect the first
    tracker.record(toolName: "read", argsHash: 1, resultHash: 10)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 1) == 3)
    #expect(tracker.preflightCount(toolName: "read", argsHash: 1) == 1)
  }

  // MARK: - Reset clears everything

  @Test func resetClearsAllState() {
    var tracker = ToolCallRepetitionTracker()

    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 3)

    tracker.reset()

    #expect(tracker.preflightCount(toolName: "list_files", argsHash: 42) == 0)
    let count = tracker.record(toolName: "list_files", argsHash: 42, resultHash: 99)
    #expect(count == 1)
  }

  // MARK: - Preflight returns 0 for unknown tools

  @Test func preflightReturnsZeroForUnknownTool() {
    let tracker = ToolCallRepetitionTracker()
    #expect(tracker.preflightCount(toolName: "unknown", argsHash: 0) == 0)
  }

  // MARK: - End-to-end scenario: 5 identical calls

  @Test func endToEndFiveIdenticalCalls() {
    var tracker = ToolCallRepetitionTracker()

    let toolName = "list_child_sessions"
    let argsHash = 0 // empty args
    let resultHash = 12345

    // Call 1: normal
    let c1 = tracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    #expect(c1 == 1)
    #expect(c1 < ToolCallRepetitionTracker.warningThreshold)

    // Call 2: normal
    let c2 = tracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    #expect(c2 == 2)
    #expect(c2 < ToolCallRepetitionTracker.warningThreshold)

    // Call 3: warning threshold reached
    let c3 = tracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    #expect(c3 == 3)
    #expect(c3 >= ToolCallRepetitionTracker.warningThreshold)
    #expect(c3 < ToolCallRepetitionTracker.blockThreshold)

    // Call 4: still warning (not blocked yet)
    let c4 = tracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    #expect(c4 == 4)
    #expect(c4 >= ToolCallRepetitionTracker.warningThreshold)
    #expect(c4 < ToolCallRepetitionTracker.blockThreshold)

    // Before call 5: preflight should still allow (count is 4)
    let preflight5 = tracker.preflightCount(toolName: toolName, argsHash: argsHash)
    #expect(preflight5 == 4)
    #expect(preflight5 < ToolCallRepetitionTracker.blockThreshold)

    // Call 5: block threshold reached
    let c5 = tracker.record(toolName: toolName, argsHash: argsHash, resultHash: resultHash)
    #expect(c5 == 5)
    #expect(c5 >= ToolCallRepetitionTracker.blockThreshold)

    // Call 6 would be blocked at preflight
    let preflight6 = tracker.preflightCount(toolName: toolName, argsHash: argsHash)
    #expect(preflight6 >= ToolCallRepetitionTracker.blockThreshold)
  }

  // MARK: - Warning and block text are well-formed

  @Test func warningAndBlockTextAreNonEmpty() {
    #expect(!ToolCallRepetitionTracker.warningText.isEmpty)
    #expect(!ToolCallRepetitionTracker.blockText.isEmpty)
    #expect(ToolCallRepetitionTracker.warningText.contains("Warning"))
    #expect(ToolCallRepetitionTracker.blockText.contains("Blocked"))
    #expect(ToolCallRepetitionTracker.warningText.contains("3"))
    #expect(ToolCallRepetitionTracker.blockText.contains("5"))
  }

  // MARK: - Simulated agent loop scenario

  @Test func simulatedAgentLoopScenario() {
    // Simulate what the agent loop does: preflight check → execute → record
    var tracker = ToolCallRepetitionTracker()

    let toolName = "list_child_sessions"
    let argsHash = 0
    let resultHash = 999

    // Simulate 6 identical calls
    var warningIssued = false
    var blockedAt: Int?

    for i in 1 ... 6 {
      // Preflight check
      let preflight = tracker.preflightCount(toolName: toolName, argsHash: argsHash)
      if preflight >= ToolCallRepetitionTracker.blockThreshold {
        blockedAt = i
        break
      }

      // "Execute" the tool (simulated — result is always the same)
      let count = tracker.record(
        toolName: toolName,
        argsHash: argsHash,
        resultHash: resultHash,
      )

      if count >= ToolCallRepetitionTracker.warningThreshold, !warningIssued {
        warningIssued = true
        #expect(i == 3, "Warning should first appear on call 3")
      }
    }

    #expect(warningIssued, "A warning should have been issued")
    #expect(blockedAt == 6, "Call 6 should be blocked (after 5 recorded identical calls)")
  }
}
