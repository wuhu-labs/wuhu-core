import Foundation
import WuhuAI

public struct SessionQueue<ItemValue: Equatable & Sendable>: Equatable, Sendable {
  public var queue: [SessionQueueItem<ItemValue>] = []

  public var isEmpty: Bool {
    queue.isEmpty
  }

  public mutating func append(_ item: SessionQueueItem<ItemValue>) {
    queue.append(item)
  }

  @discardableResult
  public mutating func remove(itemWithID: UUID) -> Bool {
    let oldCount = queue.count
    queue.removeAll {
      $0.id == itemWithID
    }
    return oldCount != queue.count
  }

  public mutating func pop(max: Int? = nil) -> [SessionQueueItem<ItemValue>] {
    let k = max ?? queue.count
    let prefix = Array(queue[0..<k])
    queue.removeFirst(k)
    return prefix
  }
}

public struct SessionQueueItem<Value: Equatable & Sendable>: Equatable, Identifiable, Sendable {
  public var id: UUID
  public var value: Value
}

public enum SessionQueueAction {
  case enqueue(UUID)
  case dequeue(UUID)
}

/// Queue lanes with different semantics.
public enum UserQueueLane: String, Sendable, Hashable, Codable {
  case steer
  case followUp
}

public struct UserQueueItemValue: Equatable, Sendable {
  public var initiation: UserInitiation
  public var content: [ContentBlock]
}
