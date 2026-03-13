import Foundation
import PiAI

enum BashToolResultError: Error, Sendable, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case let .message(message): message
    }
  }
}

func formatBashToolResult(_ run: BashResult) throws -> AgentToolResult {
  let exitCode = run.exitCode
  let output = run.output
  let timedOut = run.timedOut
  let terminated = run.terminated
  let fullOutputPath = run.fullOutputPath ?? ""

  let truncation = ToolTruncation.truncateTail(output)
  var outputText = truncation.content.isEmpty ? "(no output)" : truncation.content

  var details: [String: JSONValue] = [:]
  if truncation.truncated {
    details["truncation"] = truncation.toJSON()
    if !fullOutputPath.isEmpty {
      details["fullOutputPath"] = .string(fullOutputPath)
    }

    let startLine = truncation.totalLines - truncation.outputLines + 1
    let endLine = truncation.totalLines
    if truncation.lastLinePartial {
      let last = output.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
      let lastSize = ToolTruncation.formatSize(last.utf8.count)
      if !outputText.isEmpty { outputText += "\n\n" }
      outputText += "[Showing last \(ToolTruncation.formatSize(truncation.outputBytes)) of line \(endLine) (line is \(lastSize))."
      if !fullOutputPath.isEmpty { outputText += " Full output: \(fullOutputPath)" }
      outputText += "]"
    } else if truncation.truncatedBy == "lines" {
      outputText += "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines)."
      if !fullOutputPath.isEmpty { outputText += " Full output: \(fullOutputPath)" }
      outputText += "]"
    } else {
      outputText += "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines) (\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit)."
      if !fullOutputPath.isEmpty { outputText += " Full output: \(fullOutputPath)" }
      outputText += "]"
    }
  }

  if timedOut {
    if !fullOutputPath.isEmpty { try? FileManager.default.removeItem(atPath: fullOutputPath) }
    throw BashToolResultError.message(outputText + "\n\nCommand timed out")
  }
  if terminated {
    if !fullOutputPath.isEmpty { try? FileManager.default.removeItem(atPath: fullOutputPath) }
    throw BashToolResultError.message(outputText + "\n\nCommand aborted")
  }
  if exitCode != 0 {
    throw BashToolResultError.message(outputText + "\n\nCommand exited with code \(exitCode)")
  }

  if !truncation.truncated, !fullOutputPath.isEmpty {
    try? FileManager.default.removeItem(atPath: fullOutputPath)
  }
  return AgentToolResult(content: [.text(outputText)], details: details.isEmpty ? .object([:]) : .object(details))
}
