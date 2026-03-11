import Foundation

/// A handle for sending actions back into an ``EffectLoop`` from within a
/// long-running effect task.
///
/// `Send` is `@Sendable` and can be called from any context.
public struct Send<Action: Sendable>: Sendable {
  let _send: @Sendable (Action) async -> Void

  public func callAsFunction(_ action: Action) async {
    await _send(action)
  }
}

/// A unit of work produced by a ``LoopBehavior``.
///
/// This effect model intentionally stays primitive:
/// - `.sync` is awaited inline with exclusive mutable access to state.
/// - `.run` is spawned as a named task (deferred until sync work drains).
/// - `.cancel` cancels named tasks (batch).
///
/// There is no effect merging/batching API. Greedy draining happens in the loop.
public indirect enum Effect<State: Sendable, Action: Sendable, TaskID: Hashable & Sendable>: Sendable {
  /// No-op.
  case none

  /// Serialized async work with exclusive mutable access to state.
  ///
  /// The closure receives `inout State` (via copy-dance in the actor) and
  /// can mutate it directly. While awaiting, incoming actions are queued
  /// but not reduced. Returns actions that are still reduced after the
  /// closure completes (transitional — prefer direct state mutation).
  case sync(@Sendable (inout State) async throws -> [Action])

  /// Long-running work in a named task. Use `TaskID` for cancellation.
  case run(TaskID, @Sendable (Send<Action>) async throws -> Void)

  /// Cancel named tasks (batch).
  case cancel([TaskID])
}
