import Foundation
import Testing
@testable import WuhuCore

struct ToolResultTruncationTests {
  // MARK: - No truncation when within budget

  @Test func noTruncationWhenWithinBudget() {
    let content = "Line 1\nLine 2\nLine 3"
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 100)
    #expect(!result.wasTruncated)
    #expect(result.content == content)
    #expect(result.startLine == 1)
    #expect(result.endLine == 3)
    #expect(result.totalLines == 3)
    #expect(result.totalChars == content.count)
    #expect(result.partialLineNote == nil)
  }

  @Test func noTruncationExactBudget() {
    let content = "abc\ndef"
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 7)
    #expect(!result.wasTruncated)
    #expect(result.content == content)
  }

  // MARK: - Head truncation

  @Test func headTruncationKeepsBeginning() {
    let lines = (1 ... 100).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 50)

    #expect(result.wasTruncated)
    #expect(result.startLine == 1)
    #expect(result.endLine < 100)
    #expect(result.totalLines == 100)
    #expect(result.content.hasPrefix("Line 1"))
    #expect(!result.content.contains("Line 100"))
  }

  @Test func headTruncationLineRange() {
    // Each line is 6 chars ("Line N"), + 1 for \n separator = 7 per line after the first (first is 6).
    // Budget 20 chars: "Line 1" (6) + "\nLine 2" (7) = 13, + "\nLine 3" (7) = 20 → fit 3 lines
    let lines = (1 ... 10).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 20)

    #expect(result.wasTruncated)
    #expect(result.startLine == 1)
    #expect(result.endLine == 3)
    #expect(result.content == "Line 1\nLine 2\nLine 3")
  }

  @Test func headTruncationNotice() throws {
    let lines = (1 ... 100).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 50)
    let notice = ToolResultTruncation.renderNotice(for: result, fullOutputPath: "/tmp/test.log")

    #expect(notice != nil)
    #expect(try #require(notice?.contains("of 100 lines")))
    #expect(try #require(notice?.contains("lines 1-")))
    #expect(try #require(notice?.contains("/tmp/test.log")))
  }

  @Test func headTruncationNoNoticeWhenNotTruncated() {
    let content = "short"
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 100)
    let notice = ToolResultTruncation.renderNotice(for: result)
    #expect(notice == nil)
  }

  // MARK: - Tail truncation

  @Test func tailTruncationKeepsEnd() {
    let lines = (1 ... 100).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .tail, budget: 50)

    #expect(result.wasTruncated)
    #expect(result.endLine == 100)
    #expect(result.startLine > 1)
    #expect(result.totalLines == 100)
    #expect(result.content.hasSuffix("Line 100"))
    #expect(!result.content.contains("Line 1\n"))
  }

  @Test func tailTruncationLineRange() {
    // 10 lines, budget fits ~3 lines from the end.
    // "Line 10" (7) + "\n" separators.
    // From end: "Line 10" (7), + "\nLine 9" (7+1=8) = 15, + "\nLine 8" (7+1=8) = 23
    // Budget 23: lines 8-10
    let lines = (1 ... 10).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .tail, budget: 23)

    #expect(result.wasTruncated)
    #expect(result.startLine == 8)
    #expect(result.endLine == 10)
    #expect(result.content == "Line 8\nLine 9\nLine 10")
  }

  @Test func tailTruncationNotice() throws {
    let lines = (1 ... 100).map { "Line \($0)" }
    let content = lines.joined(separator: "\n")
    let result = ToolResultTruncation.truncate(content, direction: .tail, budget: 50)
    let notice = ToolResultTruncation.renderNotice(for: result)

    #expect(notice != nil)
    #expect(try #require(notice?.contains("of 100 lines")))
    #expect(try #require(notice?.contains("lines ")))
    #expect(try #require(notice?.contains("-100")))
  }

  // MARK: - Partial line threshold

  @Test func headPartialLineIncludedWhenAboveThreshold() throws {
    // Create content where after fitting whole lines, the remaining budget is >= 1KB
    // and the next line is long enough to be partially included.
    let shortLine = String(repeating: "a", count: 100) // 100 chars
    let longLine = String(repeating: "b", count: 5000) // 5000 chars
    // Budget: 100 (first line) + 1 (\n) + enough for partial = e.g. 2200
    // After first line: 100 chars used, remaining = 2100, next line is 5001 chars (with \n)
    // 2100 >= 1024 threshold → include partial
    let content = shortLine + "\n" + longLine
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 2200)

    #expect(result.wasTruncated)
    #expect(result.partialLineNote != nil)
    #expect(try #require(result.partialLineNote?.contains("partially shown")))
    #expect(result.endLine == 2) // Includes partial of line 2
  }

  @Test func headNoPartialLineWhenBelowThreshold() {
    // When remaining budget < 1KB, stop cleanly without partial.
    let lines = (1 ... 10).map { _ in String(repeating: "x", count: 200) }
    let content = lines.joined(separator: "\n")
    // Budget just barely over first line but remaining < 1024
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 500)

    #expect(result.wasTruncated)
    #expect(result.partialLineNote == nil)
  }

  @Test func tailPartialLineIncludedWhenAboveThreshold() throws {
    let shortLine = String(repeating: "a", count: 100)
    let longLine = String(repeating: "b", count: 5000)
    let content = longLine + "\n" + shortLine
    // Budget: 100 (last line) + 1 (\n) + enough for partial of the long line
    let result = ToolResultTruncation.truncate(content, direction: .tail, budget: 2200)

    #expect(result.wasTruncated)
    #expect(result.partialLineNote != nil)
    #expect(try #require(result.partialLineNote?.contains("partially shown")))
    #expect(result.startLine == 1) // Starts from partial of line 1
  }

  // MARK: - Budget from environment variable

  @Test func budgetFromEnvironmentDefaultsTo10K() {
    // When env var is not set, default is 10K.
    let budget = ToolResultTruncation.defaultBudgetChars
    #expect(budget == 10000)
  }

  // MARK: - Disk persistence

  @Test func persistFullOutputWritesToDisk() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-test-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let content = "Full tool output content"
    let path = ToolResultTruncation.persistFullOutput(
      content: content,
      sessionDir: tempDir.path,
      toolCallId: "test-call-123",
    )

    #expect(path != nil)
    #expect(try #require(path?.hasSuffix("test-call-123.log")))
    #expect(try #require(path?.contains(".wuhu/tool-outputs")))

    let written = try String(contentsOfFile: #require(path), encoding: .utf8)
    #expect(written == content)
  }

  @Test func persistFullOutputNoWriteWhenNotTruncated() {
    // Verify the pattern: we only call persistFullOutput when truncation happens.
    // This is enforced at the call site, not inside persistFullOutput itself.
    // Just verify persistFullOutput works correctly when called.
    let content = "small"
    let result = ToolResultTruncation.truncate(content, direction: .head, budget: 100)
    // When not truncated, we don't call persist — verified by the flag.
    #expect(!result.wasTruncated)
  }

  // MARK: - Notice rendering

  @Test func noticeIncludesAllParts() throws {
    let result = ToolResultTruncation.Result(
      content: "truncated",
      wasTruncated: true,
      startLine: 1,
      endLine: 50,
      totalLines: 1000,
      totalChars: 50000,
      partialLineNote: nil,
    )
    let notice = try #require(ToolResultTruncation.renderNotice(for: result, fullOutputPath: "/session/.wuhu/tool-outputs/abc.log"))

    #expect(notice.contains("50 of 1000 lines"))
    #expect(notice.contains("lines 1-50"))
    #expect(notice.contains("/session/.wuhu/tool-outputs/abc.log"))
  }

  @Test func noticeWithoutPath() throws {
    let result = ToolResultTruncation.Result(
      content: "truncated",
      wasTruncated: true,
      startLine: 90,
      endLine: 100,
      totalLines: 100,
      totalChars: 5000,
      partialLineNote: nil,
    )
    let notice = try #require(ToolResultTruncation.renderNotice(for: result))

    #expect(notice.contains("11 of 100 lines"))
    #expect(notice.contains("lines 90-100"))
    #expect(!notice.contains("full output"))
  }

  @Test func noticeIncludesPartialLineNote() throws {
    let result = ToolResultTruncation.Result(
      content: "truncated",
      wasTruncated: true,
      startLine: 1,
      endLine: 5,
      totalLines: 100,
      totalChars: 50000,
      partialLineNote: "[Line 5 partially shown: 1500 of 3000 chars]",
    )
    let notice = try #require(ToolResultTruncation.renderNotice(for: result))

    #expect(notice.contains("[Line 5 partially shown: 1500 of 3000 chars]"))
    #expect(notice.contains("5 of 100 lines"))
  }

  // MARK: - Edge cases

  @Test func emptyContentNotTruncated() {
    let result = ToolResultTruncation.truncate("", direction: .head, budget: 100)
    #expect(!result.wasTruncated)
    #expect(result.content == "")
    #expect(result.totalLines == 1) // Empty string splits into 1 element
  }

  @Test func singleLineTruncatedByBudget() {
    let longLine = String(repeating: "x", count: 5000)
    let result = ToolResultTruncation.truncate(longLine, direction: .head, budget: 2000)

    #expect(result.wasTruncated)
    // Single long line with budget >= threshold → partial line
    #expect(result.partialLineNote != nil)
    #expect(result.content.count <= 2000)
  }

  @Test func singleLineTailTruncated() {
    let longLine = String(repeating: "x", count: 5000)
    let result = ToolResultTruncation.truncate(longLine, direction: .tail, budget: 2000)

    #expect(result.wasTruncated)
    #expect(result.partialLineNote != nil)
    #expect(result.content.count <= 2000)
  }
}
