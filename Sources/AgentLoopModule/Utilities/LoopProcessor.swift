import Synchronization

final class LoopProcessor: Sendable {
  private let work: @Sendable () async throws -> Void
  private let onError: @Sendable (any Error) -> Void
  private let stream: AsyncStream<Void>
  private let cont: AsyncStream<Void>.Continuation

  private let started = Mutex(false)

  init(
    work: @escaping @Sendable () async throws -> Void,
    onError: @escaping @Sendable (any Error) -> Void = { print($0) },
  ) {
    let (stream, cont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    self.stream = stream
    self.cont = cont
    self.work = work
    self.onError = onError
  }

  deinit {
    cont.finish()
  }

  func start() async {
    started.withLock { started in
      precondition(!started)
      started = true
    }

    for await _ in stream {
      do {
        try await work()
      } catch is CancellationError {
      } catch {
        onError(error)
      }
    }
  }

  func nudge() {
    cont.yield()
  }
}
