import Foundation

public actor AsyncCondition<Value: Sendable> {
  private var value: Value
  private var waiters: [UUID: Waiter<Value>] = [:]

  public init(_ value: Value) {
    self.value = value
  }

  public func current() -> Value {
    value
  }

  public func set(_ newValue: Value) {
    value = newValue

    let ready = waiters.filter { $0.value.predicate(newValue) }
    for (id, waiter) in ready {
      waiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  public func waitUntil(
    _ predicate: @escaping @Sendable (Value) -> Bool,
  ) async throws {
    let id = UUID()

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if predicate(value) {
          continuation.resume()
          return
        }

        waiters[id] = .init(predicate: predicate, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id, error: CancellationError()) }
    }
  }

  public func failAll(with error: any Error) {
    let currentWaiters = waiters
    waiters.removeAll()
    for (_, waiter) in currentWaiters {
      waiter.continuation.resume(throwing: error)
    }
  }

  private func cancelWaiter(_ id: UUID, error: any Error) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: error)
  }
}

public extension AsyncCondition where Value: Comparable {
  func waitUntil(atLeast target: Value) async throws {
    try await waitUntil { $0 >= target }
  }
}

private struct Waiter<Value>: Sendable {
  let predicate: @Sendable (Value) -> Bool
  let continuation: CheckedContinuation<Void, Error>
}
