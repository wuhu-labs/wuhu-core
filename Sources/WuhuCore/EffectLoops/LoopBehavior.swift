/// The domain-specific logic that drives an ``EffectLoop``.
///
/// A behavior defines:
/// - **State**: the full in-memory state of the loop.
/// - **Action**: every possible state mutation.
/// - **reduce**: pure, synchronous state transition that may return an effect.
/// - **nextEffect**: a planner that can schedule more effects based on state.
///
/// The loop drains effects greedily until `nextEffect` returns `nil`.
public protocol LoopBehavior<State, Action>: Sendable {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Named tasks are tracked by the loop for cancellation.
  associatedtype TaskID: Hashable & Sendable = String

  /// Pure reducer. Apply an action to state and optionally return an effect.
  ///
  /// Must be synchronous — no IO, no suspension.
  func reduce(state: inout State, action: Action) -> Effect<State, Action, TaskID>

  /// Inspect current state and return the next effect to run,
  /// or `nil` if the loop should idle.
  ///
  /// May mutate state to set guard tokens (e.g. marking a task as scheduled)
  /// so greedy draining does not repeatedly schedule the same work.
  func nextEffect(state: inout State) -> Effect<State, Action, TaskID>?

  /// Wraps the execution of a spawned task.
  ///
  /// The default implementation calls through directly. Override to inject
  /// context (e.g. dependency overrides) around effect execution.
  func run(_ work: @escaping @Sendable () async throws -> Void) async throws
}

public extension LoopBehavior {
  func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
    try await work()
  }
}
