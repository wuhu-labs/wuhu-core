import Synchronization

final class DeferredExecutionCoordinatorBase<Action: Sendable, Interruption>: Sendable {
  typealias ActionHandler = @Sendable (_ action: Action) -> Void
  public typealias CancellationHandler = @Sendable (_ interruption: Interruption?) -> Void

  let onAction: ActionHandler
  let onCancelStorage: Mutex<CancellationHandler?> = .init(nil)

  init(onAction: @escaping ActionHandler) {
    self.onAction = onAction
  }

  func send(_ action: Action) {
    onAction(action)
  }

  func setCancellationHandler(body: @escaping CancellationHandler) {
    onCancelStorage.withLock {
      assert($0 == nil, "Called onCancel for more than once.")
      $0 = body
    }
  }

  func cancel(with interruption: Interruption?) {
    onCancelStorage.withLock { onCancel in
      guard let onCancel else { return }
      onCancel(interruption)
    }
  }
}

public struct DeferredExecutionCoordinator<Action: Sendable, Interruption>: Sendable {
  typealias ActionHandler = @Sendable (_ action: Action) -> Void
  typealias SetCancellationHandler = @Sendable (@escaping CancellationHandler) -> Void
  public typealias CancellationHandler = @Sendable (_ interruption: Interruption?) -> Void

  let onAction: ActionHandler
  let onSetCancellation: SetCancellationHandler
  let onCancel: CancellationHandler

  init(
    onAction: @escaping ActionHandler,
    onSetCancellation: @escaping SetCancellationHandler,
    onCancel: @escaping CancellationHandler

  ) {
    self.onAction = onAction
    self.onSetCancellation = onSetCancellation
    self.onCancel = onCancel
  }

  init(
    onAction: @escaping ActionHandler
  ) {
    let base = DeferredExecutionCoordinatorBase<Action, Interruption>(onAction: onAction)
    self.onAction = { base.onAction($0) }
    self.onSetCancellation = { base.setCancellationHandler(body: $0) }
    self.onCancel = { base.cancel(with: $0) }
  }

  public func send(_ action: Action) {
    onAction(action)
  }

  public func setCancellationHandler(body: @escaping CancellationHandler) {
    onSetCancellation(body)
  }

  func cancel(with interruption: Interruption?) {
    onCancel(interruption)
  }

  public func embed<LocalAction>(
    _ embed: @escaping @Sendable (LocalAction) -> Action
  ) -> DeferredExecutionCoordinator<LocalAction, Interruption> {
    .init(onAction: {
      self.onAction(embed($0))
    }, onSetCancellation: self.onSetCancellation, onCancel: self.onCancel)
  }
}

public struct DeferredExecution<Action: Sendable, Interruption>: Sendable {
  public typealias Coordinator = DeferredExecutionCoordinator<Action, Interruption>

  let needsPersistence: Bool
  let run: @Sendable (_ coordinator: Coordinator) async throws -> Void

  public init(
    needsPersistence: Bool = true,
    run: @escaping @Sendable (_ coordinator: Coordinator) async throws -> Void
  ) {
    self.needsPersistence = needsPersistence
    self.run = run
  }

  public func map<ParentAction>(
    needsPersistence: Bool? = nil,
    _ embed: @escaping @Sendable (Action) -> ParentAction
  ) -> DeferredExecution<ParentAction, Interruption> {

    return DeferredExecution<ParentAction, Interruption>(
      needsPersistence: needsPersistence ?? self.needsPersistence,
      run: { coordinator in
        try await self.run(coordinator.embed(embed))
      }
    )
  }

  public static var none: Self {
    .init { _ in }
  }
}
