/// The domain-specific logic that drives an ``EffectLoop``.
///
/// A behavior defines:
/// - **State**: the full in-memory state of the loop.
/// - **Action**: every possible state mutation.
/// - **reduce**: pure, synchronous state transition.
/// - **nextEffect**: inspects state and returns the next side effect
///   to run, or `nil` if idle.
///
/// The loop calls `nextEffect` greedily after every reduce — it
/// keeps pulling effects until `nil`, then waits for the next action.
///
/// ## Design
///
/// All scheduling logic lives in `nextEffect`. The priority ordering
/// of what to do next (crash recovery → interrupt drain → inference →
/// compaction) is expressed as early returns in a single function body.
/// No wide protocol surface, no scattered lifecycle hooks.
public protocol LoopBehavior<State, Action>: Sendable {
  associatedtype State: Sendable
  associatedtype Action: Sendable

  /// Pure reducer. Apply an action to state.
  ///
  /// Must be synchronous — no IO, no suspension.
  func reduce(state: inout State, action: Action)

  /// Inspect current state and return the next effect to run,
  /// or `nil` if the loop should idle.
  ///
  /// Called after every reduce. The loop calls this repeatedly
  /// until it returns `nil`, then waits for an external action.
  ///
  /// - Important: This mutates state so you can set guard tokens
  ///   (e.g. `state.isGenerating = true`) to prevent re-entry
  ///   on the next call.
  func nextEffect(state: inout State) -> Effect<Action>?

  /// Wraps the execution of an effect's async work.
  ///
  /// The default implementation calls through directly. Override to
  /// inject context (e.g. dependency overrides) around effect execution.
  func run(_ work: @escaping @Sendable () async throws -> Void) async throws
}

extension LoopBehavior {
  public func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
    try await work()
  }
}
