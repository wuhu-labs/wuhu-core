/// A unit of asynchronous work that can send actions back into an
/// ``EffectLoop``.
///
/// Effects are the only way to perform side effects (network calls,
/// persistence, timers). They run concurrently with the loop and
/// feed results back via ``Send``.
///
/// ## Creating Effects
///
///     // Fire-and-forget async work:
///     Effect { send in
///       let result = try await api.fetch()
///       await send(.fetched(result))
///     }
///
///     // Synchronous action (no async work):
///     Effect.send(.increment)
///
///     // No-op:
///     Effect.none
public struct Effect<Action: Sendable>: Sendable {
  enum Operation: Sendable {
    case none
    case send(Action)
    case run(@Sendable (Send<Action>) async throws -> Void)
  }

  let operation: Operation

  private init(_ operation: Operation) {
    self.operation = operation
  }

  /// An effect that does nothing.
  public static var none: Effect {
    Effect(.none)
  }

  /// An effect that synchronously sends a single action.
  public static func send(_ action: Action) -> Effect {
    Effect(.send(action))
  }

  /// An effect that runs an async closure. The closure receives a
  /// ``Send`` function to feed actions back into the loop.
  public init(_ run: @escaping @Sendable (Send<Action>) async throws -> Void) {
    operation = .run(run)
  }
}

/// A handle for sending actions back into an ``EffectLoop`` from
/// within an effect's async closure.
///
/// `Send` is `@Sendable` and can be called from any context.
public struct Send<Action: Sendable>: Sendable {
  let _send: @Sendable (Action) async -> Void

  public func callAsFunction(_ action: Action) async {
    await _send(action)
  }
}
