import Foundation
import WuhuAI

public enum AgentContextAction {
  case inference
  case drain
}

/// Domain-specific behavior that drives an ``AgentLoop``.
///
/// The loop keeps a live in-memory state, orchestrates the
/// tools → drain → infer → compact cycle, and only publishes new state
/// to observers after the behavior has durably persisted the changes.
///
/// Implementors provide the state shape, scheduling queries, execution
/// handles, persistence logic, and external action handling.
public protocol AgentBehavior: Sendable {

  // MARK: - State

  /// Full state held by the loop. Opaque to the loop; must be equatable
  /// so the loop can detect when persistence is needed.
  associatedtype State: Sendable & Equatable

  /// Domain-specific commands sent into the loop from outside.
  associatedtype Action: Sendable

  /// Reason attached to an interruption (e.g. user-initiated stop).
  associatedtype Interruption: Sendable

  /// The result of executing a tool call. Opaque to the loop — it just
  /// passes the value from ``startToolCall(_:state:)`` back to
  /// ``persistToolResult(_:for:state:)``.
  associatedtype ToolResult: Sendable

  /// Behavior-specific representation of the changes between two state
  /// versions, used for durable persistence.
  associatedtype PersistenceDiff: Sendable

  // MARK: - External Actions

  /// Handle a command from outside the loop by mutating in-memory state.
  ///
  /// Return an ``Interruption`` to cancel the current running task
  /// (e.g. user clicked stop), or `nil` for normal actions.
  func handle(_ action: Action, state: inout State) -> Interruption?

  // MARK: - Scheduling

  /// Return the next pending tool call, or `nil` if none remain.
  ///
  /// The loop executes tool calls with highest priority. While this
  /// returns non-nil, the loop keeps executing tool calls before
  /// moving on to drain or inference.
  func nextToolCall(state: State) -> ToolCall?

  /// Whether the state requires an inference call.
  ///
  /// Checked after tool calls are exhausted. Returns `true` when the
  /// transcript ends with content the model has not yet responded to
  /// (e.g. a user message, a tool result, or a failed prior inference).
  func nextContextAction(state: State) -> AgentContextAction?

  /// Whether compaction should run.
  ///
  /// Checked after inference is not needed. Lowest priority in the
  /// loop's scheduling order.
  func shouldCompact(state: State) -> Bool

  // MARK: - Drain

  /// Drain queued items into the in-memory state.
  ///
  /// Called after all tool calls for a turn have completed, before
  /// the loop re-evaluates scheduling. Use this to materialize
  /// interrupt-priority or turn-boundary items into the transcript.
  func drainToContext(state: inout State)

  // MARK: - Execution

  /// Project current state into the LLM input context.
  ///
  /// Pure function of state — no IO.
  func buildContext(state: State) -> Context

  /// Return a deferred execution handle for inference.
  ///
  /// The loop ensures state is durably persisted before invoking the
  /// handle. If the process crashes during inference, the loop retries
  /// on restart (inference is the only IO that is not persisted before
  /// returning).
  func infer(context: Context, state: inout State) -> DeferredExecution<Action, Interruption>

  /// Mutate in-memory bookkeeping for a tool call and return a deferred
  /// execution handle for the actual work.
  ///
  /// The loop persists the mutated state before invoking the handle.
  func startToolCall(
    _ call: ToolCall,
    state: inout State,
  ) -> DeferredExecution<Action, Interruption>

  /// Return a deferred execution handle for compaction.
  ///
  /// Compaction results should be fed back into the loop via an action
  /// sent through the coordinator.
  func performCompaction(state: inout State) -> DeferredExecution<Action, Interruption>

  // MARK: - Durable Persistence

  /// Compute the diff between two state versions for persistence.
  ///
  /// The final persistence when the loop is cancelled won't be retryed, detect via Task.isCancelled and handle accordingly.
  func diff(from oldState: State, to newState: State) -> PersistenceDiff?

  /// Persist a previously computed diff to durable storage.
  func persist(_ diff: PersistenceDiff) async throws

  /// When enabled, it is your job to do proper backoff. Default to false.
  var autoRetryFailedPersistence: Bool { get }
}

extension AgentBehavior {
  public var autoRetryFailedPersistence: Bool { false }
}
