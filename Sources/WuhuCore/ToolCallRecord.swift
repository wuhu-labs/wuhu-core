import Foundation

struct ToolCallRecord: Sendable, Hashable, Equatable {
  var status: ToolCallStatus
  var updatedAt: Date

  init(status: ToolCallStatus, updatedAt: Date = Date()) {
    self.status = status
    self.updatedAt = updatedAt
  }
}
