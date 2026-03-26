import Foundation

struct MonotonicWaiters<Value: Comparable> {
  private var currentValue: Value
  private var waiters: [UUID: Waiter<Value>] = [:]

  init(current: Value) {
    currentValue = current
  }

  var current: Value {
    currentValue
  }

  mutating func register(
    id: UUID,
    until target: Value,
    continuation: CheckedContinuation<Void, Error>,
  ) -> Bool {
    guard currentValue < target else {
      continuation.resume()
      return false
    }

    waiters[id] = Waiter(target: target, continuation: continuation)
    return true
  }

  mutating func advance(to value: Value) {
    guard currentValue < value else { return }
    currentValue = value

    let ready = waiters.filter { $0.value.target <= value }
    for (id, waiter) in ready {
      waiters.removeValue(forKey: id)
      waiter.continuation.resume()
    }
  }

  mutating func cancel(id: UUID, error: any Error) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: error)
  }

  mutating func failAll(with error: any Error) {
    let currentWaiters = waiters
    waiters.removeAll()
    for (_, waiter) in currentWaiters {
      waiter.continuation.resume(throwing: error)
    }
  }
}

private struct Waiter<Value: Comparable> {
  let target: Value
  let continuation: CheckedContinuation<Void, Error>
}
