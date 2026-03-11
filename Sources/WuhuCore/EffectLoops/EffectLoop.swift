import Foundation

/// A lightweight, generic effect loop runtime.
///
/// Holds state, runs a ``LoopBehavior``, serializes mutations,
/// and fans out observations.
///
/// ## Key semantics
///
/// - `send(_:)` enqueues actions; it does not reduce immediately.
/// - `.sync` effects are awaited inline and yield committed actions.
/// - `.run` effects are deferred until all `.sync` work drains.
/// - The loop drains greedily until there are no queued actions and
///   `nextEffect` returns `nil`.
public actor EffectLoop<B: LoopBehavior> {
  public private(set) var state: B.State
  private let behavior: B

  // MARK: - Signal

  private var signal: AsyncStream<Void>.Continuation?

  // MARK: - Pending actions

  private var pendingActions: [B.Action] = []

  // MARK: - Named tasks

  private var tasks: [B.TaskID: Task<Void, Never>] = [:]

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

  /// Enqueue an action and wake the loop.
  public func send(_ action: B.Action) {
    pendingActions.append(action)
    signal?.yield(())
  }

  // MARK: - Lifecycle

  /// Start the loop. Blocks until cancelled.
  public func start() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1),
    )
    signal = continuation

    defer { cancelAllTasks() }

    // Initial step — behavior may have work from initial state.
    await step()

    for await _ in stream {
      await step()
    }
  }

  // MARK: - Step

  private struct DeferredRun {
    let id: B.TaskID
    let work: @Sendable (Send<B.Action>) async throws -> Void
  }

  /// Drain queued actions and planner effects until idle.
  private func step() async {
    var deferredRuns: [DeferredRun] = []
    var deferredIDs: Set<B.TaskID> = []

    while true {
      // 1) Drain actions.
      var actionIndex = 0
      while actionIndex < pendingActions.count {
        let action = pendingActions[actionIndex]
        actionIndex += 1

        let effect = behavior.reduce(state: &state, action: action)
        notifyObservers(action)
        await handle(effect, deferredRuns: &deferredRuns, deferredIDs: &deferredIDs)

        // After each action, greedily pull planner effects.
        while let planned = behavior.nextEffect(state: &state) {
          await handle(planned, deferredRuns: &deferredRuns, deferredIDs: &deferredIDs)
          if pendingActions.count > actionIndex { break }
        }
      }
      if actionIndex > 0 {
        pendingActions.removeFirst(actionIndex)
      }

      // 2) No queued actions. Pull planner effects.
      guard let planned = behavior.nextEffect(state: &state) else {
        break
      }
      await handle(planned, deferredRuns: &deferredRuns, deferredIDs: &deferredIDs)
    }

    // 3) After all sync work is drained, start deferred runs.
    flushDeferredRuns(&deferredRuns)
  }

  private func handle(
    _ effect: Effect<B.State, B.Action, B.TaskID>,
    deferredRuns: inout [DeferredRun],
    deferredIDs: inout Set<B.TaskID>,
  ) async {
    switch effect {
    case .none:
      return

    case let .cancel(ids):
      for id in ids {
        // Cancel in-flight tasks.
        tasks.removeValue(forKey: id)?.cancel()

        // Remove any scheduled-but-not-yet-started work.
        if deferredIDs.contains(id) {
          deferredIDs.remove(id)
          deferredRuns.removeAll(where: { $0.id == id })
        }
      }
      return

    case let .run(id, work):
      precondition(tasks[id] == nil, "Task already running for id: \(id)")
      precondition(!deferredIDs.contains(id), "Task already scheduled for id: \(id)")
      deferredIDs.insert(id)
      deferredRuns.append(DeferredRun(id: id, work: work))
      return

    case let .sync(work):
      // Copy dance: Swift forbids passing actor-isolated state as inout
      // into an async closure. We copy out, let the closure mutate, then
      // copy back — the actor provides exclusive access throughout.
      var copy = state
      let actions: [B.Action]
      do {
        actions = try await work(&copy)
      } catch is CancellationError {
        return
      } catch {
        // Domain-specific error handling should be encoded via returned actions.
        // Unhandled errors are dropped.
        return
      }
      state = copy

      // Commit returned actions immediately.
      for action in actions {
        let eff = behavior.reduce(state: &state, action: action)
        notifyObservers(action)
        await handle(eff, deferredRuns: &deferredRuns, deferredIDs: &deferredIDs)
      }
      return
    }
  }

  private func flushDeferredRuns(_ deferredRuns: inout [DeferredRun]) {
    for run in deferredRuns {
      let id = run.id
      let work = run.work

      precondition(tasks[id] == nil, "Task already running for id: \(id)")

      let sendFn = Send<B.Action> { [weak self] action in
        await self?.send(action)
      }
      let behavior = behavior

      let task = Task { [weak self] in
        defer { Task { [weak self] in await self?.removeTask(id) } }
        do {
          try await behavior.run {
            try await work(sendFn)
          }
        } catch is CancellationError {
          // Normal cancellation.
        } catch {
          // Spawned tasks handle errors by sending error actions.
          // Unhandled errors are dropped.
        }
      }

      tasks[id] = task
    }
    deferredRuns.removeAll()
  }

  private func removeTask(_ id: B.TaskID) {
    tasks.removeValue(forKey: id)
  }

  private func cancelAllTasks() {
    for (_, task) in tasks {
      task.cancel()
    }
    tasks.removeAll()
  }

  // MARK: - Observation

  /// Subscribe to actions as they are reduced.
  ///
  /// Returns the current state snapshot and a stream of subsequent actions.
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
