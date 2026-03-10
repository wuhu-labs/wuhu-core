import Foundation

struct ToolMessageError: Error, Sendable, CustomStringConvertible, Hashable {
  var message: String

  var description: String {
    message
  }
}
