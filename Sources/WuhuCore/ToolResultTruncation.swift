import Foundation

/// Per-tool intelligent truncation system.
///
/// Truncates tool result text on line boundaries with a configurable character
/// budget. When truncation occurs, appends a neutral notice with line counts,
/// line range, and the path to the full output on disk.
public enum ToolResultTruncation {
  /// Direction of truncation.
  public enum Direction: Sendable, Hashable {
    /// Keep the beginning, drop the end (default for most tools).
    case head
    /// Keep the end, drop the beginning (used by bash — build/test output is most useful at the tail).
    case tail
  }

  /// Default budget in characters.
  public static let defaultBudgetChars = 10000

  /// Partial-line threshold in characters. If remaining budget after whole
  /// lines is ≥ this value and the next line would fit partially, include
  /// a partial line with an annotation.
  public static let partialLineThreshold = 1024

  /// Read the budget from the environment, falling back to the default.
  public static var budgetFromEnvironment: Int {
    if let raw = ProcessInfo.processInfo.environment["WUHU_TOOL_RESULT_BUDGET_CHARS"],
       let value = Int(raw), value > 0
    {
      return value
    }
    return defaultBudgetChars
  }

  /// Result of truncation.
  public struct Result: Sendable {
    /// The (possibly truncated) content.
    public var content: String
    /// Whether truncation was applied.
    public var wasTruncated: Bool
    /// 1-indexed start line of the shown range.
    public var startLine: Int
    /// 1-indexed end line of the shown range.
    public var endLine: Int
    /// Total number of lines in the original content.
    public var totalLines: Int
    /// Total number of characters in the original content.
    public var totalChars: Int
    /// If a partial line was included, the annotation text. Nil otherwise.
    public var partialLineNote: String?
  }

  /// Truncate `content` to fit within `budget` characters, splitting on line
  /// boundaries.
  ///
  /// - Parameters:
  ///   - content: The raw tool output.
  ///   - direction: `.head` keeps the beginning; `.tail` keeps the end.
  ///   - budget: Maximum characters of content to keep (default from env var).
  /// - Returns: A `Result` describing the truncated content and metadata.
  public static func truncate(
    _ content: String,
    direction: Direction = .head,
    budget: Int? = nil,
  ) -> Result {
    let effectiveBudget = budget ?? budgetFromEnvironment
    let totalChars = content.count

    if totalChars <= effectiveBudget {
      let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      return Result(
        content: content,
        wasTruncated: false,
        startLine: 1,
        endLine: lines.count,
        totalLines: lines.count,
        totalChars: totalChars,
        partialLineNote: nil,
      )
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let totalLines = lines.count

    switch direction {
    case .head:
      return truncateHead(lines: lines, totalLines: totalLines, totalChars: totalChars, budget: effectiveBudget)
    case .tail:
      return truncateTail(lines: lines, totalLines: totalLines, totalChars: totalChars, budget: effectiveBudget)
    }
  }

  /// Render the truncation notice to append after truncated content.
  ///
  /// - Parameters:
  ///   - result: The truncation result.
  ///   - fullOutputPath: Path to the persisted full output on disk (nil if not persisted).
  /// - Returns: The notice string (including leading newlines), or nil if no truncation.
  public static func renderNotice(for result: Result, fullOutputPath: String? = nil) -> String? {
    guard result.wasTruncated else { return nil }

    let shownLines = result.endLine - result.startLine + 1
    var parts: [String] = []
    parts.append("\(shownLines) of \(result.totalLines) lines")
    parts.append("lines \(result.startLine)-\(result.endLine)")
    if let path = fullOutputPath {
      parts.append("full output: \(path)")
    }

    var notice = "\n\n[\(parts.joined(separator: " | "))]"
    if let partial = result.partialLineNote {
      notice = "\n\(partial)" + notice
    }
    return notice
  }

  /// Persist the full output to disk when truncation occurred.
  ///
  /// - Parameters:
  ///   - content: The full (un-truncated) tool output.
  ///   - sessionDir: The session's primary mount directory.
  ///   - toolCallId: The tool call ID (used as file name).
  /// - Returns: The path to the written file, or nil on failure.
  public static func persistFullOutput(
    content: String,
    sessionDir: String,
    toolCallId: String,
  ) -> String? {
    let dir = (sessionDir as NSString).appendingPathComponent(".wuhu/tool-outputs")
    let path = (dir as NSString).appendingPathComponent("\(toolCallId).log")

    do {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
      try content.write(toFile: path, atomically: true, encoding: .utf8)
      return path
    } catch {
      return nil
    }
  }

  // MARK: - Private

  private static func truncateHead(
    lines: [String],
    totalLines: Int,
    totalChars: Int,
    budget: Int,
  ) -> Result {
    var charCount = 0
    var keptCount = 0
    var partialNote: String?

    for (i, line) in lines.enumerated() {
      let lineChars = line.count + (i > 0 ? 1 : 0) // +1 for the \n separator
      if charCount + lineChars > budget {
        // This line doesn't fit entirely. Check partial line threshold.
        let remaining = budget - charCount
        if remaining >= partialLineThreshold {
          // Include a partial line.
          let separatorCost = i > 0 ? 1 : 0
          let availableForLine = remaining - separatorCost
          let partialLine = String(line.prefix(availableForLine))
          let lineNumber = i + 1
          partialNote = "[Line \(lineNumber) partially shown: \(availableForLine) of \(line.count) chars]"
          // We need to build the content with the partial line included.
          var kept = Array(lines[0 ..< i])
          kept.append(partialLine)
          let content = kept.joined(separator: "\n")
          return Result(
            content: content,
            wasTruncated: true,
            startLine: 1,
            endLine: lineNumber,
            totalLines: totalLines,
            totalChars: totalChars,
            partialLineNote: partialNote,
          )
        }
        break
      }
      charCount += lineChars
      keptCount += 1
    }

    let content = lines[0 ..< keptCount].joined(separator: "\n")
    return Result(
      content: content,
      wasTruncated: true,
      startLine: 1,
      endLine: keptCount,
      totalLines: totalLines,
      totalChars: totalChars,
      partialLineNote: partialNote,
    )
  }

  private static func truncateTail(
    lines: [String],
    totalLines: Int,
    totalChars: Int,
    budget: Int,
  ) -> Result {
    var charCount = 0
    var keptFromEnd = 0
    var partialNote: String?

    for i in stride(from: lines.count - 1, through: 0, by: -1) {
      let line = lines[i]
      let lineChars = line.count + (keptFromEnd > 0 ? 1 : 0) // +1 for the \n separator
      if charCount + lineChars > budget {
        // This line doesn't fit entirely. Check partial line threshold.
        let remaining = budget - charCount
        if remaining >= partialLineThreshold {
          let separatorCost = keptFromEnd > 0 ? 1 : 0
          let availableForLine = remaining - separatorCost
          // Keep the end of the line.
          let partialLine = String(line.suffix(availableForLine))
          let lineNumber = i + 1
          partialNote = "[Line \(lineNumber) partially shown: \(availableForLine) of \(line.count) chars]"
          var kept = [partialLine]
          kept.append(contentsOf: lines[(i + 1)...])
          let content = kept.joined(separator: "\n")
          return Result(
            content: content,
            wasTruncated: true,
            startLine: lineNumber,
            endLine: totalLines,
            totalLines: totalLines,
            totalChars: totalChars,
            partialLineNote: partialNote,
          )
        }
        break
      }
      charCount += lineChars
      keptFromEnd += 1
    }

    let startIndex = lines.count - keptFromEnd
    let content = lines[startIndex...].joined(separator: "\n")
    return Result(
      content: content,
      wasTruncated: true,
      startLine: startIndex + 1,
      endLine: totalLines,
      totalLines: totalLines,
      totalChars: totalChars,
      partialLineNote: partialNote,
    )
  }
}
