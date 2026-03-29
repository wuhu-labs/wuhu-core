import Synchronization

public struct DeferredExecutionCoordinator<Action: Sendable>: Sendable {
  typealias ActionHandler = @Sendable (_ action: Action) -> Void

  let onAction: ActionHandler

  init(onAction: @escaping ActionHandler) {
    self.onAction = onAction
  }

  public func send(_ action: Action) {
    onAction(action)
  }

  public func embed<LocalAction>(
    _ embed: @escaping @Sendable (LocalAction) -> Action
  ) -> DeferredExecutionCoordinator<LocalAction> {
    .init { self.onAction(embed($0)) }
  }
}

public struct DeferredExecution<Action: Sendable>: Sendable {
  public typealias Coordinator = DeferredExecutionCoordinator<Action>

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
  ) -> DeferredExecution<ParentAction> {

    return DeferredExecution<ParentAction>(
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
