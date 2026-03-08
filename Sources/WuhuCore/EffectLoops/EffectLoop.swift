import Foundation

/// A lightweight, generic effect loop runtime.
///
/// Holds state, runs a ``LoopBehavior``, serializes mutations,
/// and fans out observations. Think of it as a minimal TCA Store
/// tailored for server-side agent loops.
///
/// ## Lifecycle
///
/// 1. Create the loop with a behavior and initial state.
/// 2. Call ``start()`` — this runs the step loop until cancelled.
/// 3. Send actions via ``send(_:)``.
/// 4. Observe via ``subscribe()``.
///
/// ## Serialization
///
/// All state mutations happen on the actor. Effects run concurrently
/// but feed actions back through ``send(_:)``, which is serialized.
/// The `nextEffect` call happens synchronously after each reduce,
/// so guard tokens set in `nextEffect` are visible before any
/// concurrent effect can send another action.
public actor EffectLoop<B: LoopBehavior> {
  public private(set) var state: B.State
  private let behavior: B

  // MARK: - Signal

  private var signal: AsyncStream<Void>.Continuation?

  // MARK: - Observation

  private var observers: [UUID: Observer] = [:]

  private struct Observer {
    let continuation: AsyncStream<B.Action>.Continuation
  }

  // MARK: - Init

  public init(behavior: B, initialState: B.State) {
    self.behavior = behavior
    state = initialState
  }

  // MARK: - Send

  /// Send an action into the loop.
  ///
  /// Reduces immediately, notifies observers, then wakes the step
  /// loop to pull the next effect.
  public func send(_ action: B.Action) {
    behavior.reduce(state: &state, action: action)
    notifyObservers(action)
    signal?.yield(())
  }

  // MARK: - Lifecycle

  /// Start the loop. Blocks until cancelled.
  ///
  /// After each wake (from ``send(_:)`` or effect completion), the
  /// loop calls `nextEffect` repeatedly until nil.
  public func start() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    signal = continuation

    // Initial step — behavior may have work from initial state.
    step()

    for await _ in stream {
      step()
    }
  }

  // MARK: - Step

  /// Pull effects from the behavior until idle.
  private func step() {
    while let effect = behavior.nextEffect(state: &state) {
      execute(effect)
    }
  }

  // MARK: - Execute

  private func execute(_ effect: Effect<B.Action>) {
    switch effect.operation {
    case .none:
      break
    case let .send(action):
      send(action)
    case let .run(work):
      let sendFn = Send<B.Action> { [weak self] action in
        await self?.send(action)
      }
      Task {
        do {
          try await work(sendFn)
        } catch is CancellationError {
          // Silently ignore cancellation.
        } catch {
          // Effects are responsible for their own error handling
          // by sending error actions. Unhandled errors are dropped.
        }
      }
    }
  }

  // MARK: - Observation

  /// Subscribe to actions as they are reduced.
  ///
  /// Returns the current state snapshot and a stream of subsequent
  /// actions. The registration is atomic — no actions are missed
  /// between the snapshot and the first stream element.
  public func subscribe() -> (state: B.State, actions: AsyncStream<B.Action>) {
    let id = UUID()
    let (stream, continuation) = AsyncStream<B.Action>.makeStream()
    observers[id] = Observer(continuation: continuation)
    continuation.onTermination = { [weak self] _ in
      Task { [weak self] in await self?.removeObserver(id) }
    }
    return (state, stream)
  }

  private func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  private func notifyObservers(_ action: B.Action) {
    for (_, observer) in observers {
      observer.continuation.yield(action)
    }
  }
}
