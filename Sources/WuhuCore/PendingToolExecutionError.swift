import Foundation

struct PendingToolExecutionError: Error, Sendable, CustomStringConvertible {
  var description: String {
    "Tool execution is pending external completion"
  }
}
