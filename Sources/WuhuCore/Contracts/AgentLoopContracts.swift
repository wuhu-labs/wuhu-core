import AsyncExtensions
import Foundation
import WuhuAI

// MARK: - Agent Behavior

/// Domain-specific feature that drives an ``AgentLoop``.
///
/// Owns the state shape, domain rules, persistence diffing, inference,
/// tool execution, and drain logic.
///
/// The loop keeps a live in-memory state and only makes it externally
/// visible after the behavior persists the diff from the last durable
/// state to the new state.
public protocol AgentBehavior: Sendable {
  // MARK: Associated Types

  /// Full state held by the loop.
  ///
  /// The loop treats state as an opaque value. The state must be equatable so
  /// the loop can detect when persistence work is needed.
  associatedtype State: Sendable & Equatable

  /// Behavior-specific representation of the durable changes between two
  /// versions of state.
  associatedtype PersistenceDiff: Sendable

  /// Describes an ephemeral streaming update (inference text delta, etc.).
  /// Not persisted, not applied to committed state.
  associatedtype StreamAction: Sendable

  /// Domain-specific commands from outside the loop (enqueue, cancel,
  /// change model, etc.).
  associatedtype ExternalAction: Sendable

  /// The result of executing a tool. Opaque to the loop — it just
  /// passes the value from ``startToolCall(_:state:)`` to
  /// ``persistToolResult(_:for:state:)``.
  ///
  /// `Hashable` is required so the loop can detect consecutive
  /// identical tool results (see ``ToolCallRepetitionTracker``).
  associatedtype ToolResult: Sendable & Hashable

  /// Load full state from the database. Called once on startup.
  func loadState() async throws -> State

  /// Compute the durable diff between two versions of state.
  func diff(from oldState: State, to newState: State) -> PersistenceDiff?

  /// Persist a previously computed diff and return the durable state that
  /// should replace the loop's live state before observation.
  func persist(_ diff: PersistenceDiff, from oldState: State, to newState: State) async throws -> State

  // MARK: External Actions

  /// Handle a command from outside the loop by mutating the in-memory state.
  func handle(_ action: ExternalAction, state: inout State)

  // MARK: Drain

  /// Atomically drain interrupt-priority items into the in-memory state.
  ///
  /// Called at the **interrupt checkpoint** — after tool results are
  /// collected, before next inference.
  @discardableResult
  func drainInterruptItems(state: inout State) -> Bool

  /// Atomically drain turn-boundary items into the in-memory state.
  ///
  /// Called at the **turn boundary** — the agent would otherwise go idle.
  @discardableResult
  func drainTurnItems(state: inout State) -> Bool

  // MARK: Inference

  /// Project current state into LLM input context.
  ///
  /// Pure function of state — no IO.
  func buildContext(state: State) -> Context

  /// Run inference. Yields streaming deltas to `stream` during execution.
  ///
  /// This is the only IO operation that is **not** persisted before
  /// returning. If the process crashes during inference, the loop
  /// retries on restart.
  func infer(
    context: Context,
    stream: AgentStreamSink<StreamAction>,
  ) async throws -> AssistantMessage

  // MARK: Persist Inference Results

  /// Save the assistant's response into the in-memory state.
  func persistAssistantEntry(
    _ message: AssistantMessage,
    state: inout State,
  )

  // MARK: Tool Lifecycle

  /// Returns the next tool call that should execute for the current state.
  ///
  /// This is a pure query over durable state. The loop can therefore resume
  /// pending or started work after restart without depending on a transient
  /// in-memory inference result.
  func nextToolCall(state: State) -> ToolCall?

  /// Start (or resume) a tool call by mutating in-memory bookkeeping and
  /// returning an error-free task handle for the actual work.
  ///
  /// The loop persists the mutated state before awaiting the task's value.
  func startToolCall(
    _ call: ToolCall,
    state: inout State,
  ) -> Task<ToolResult, Never>

  /// Build the tool result that should be persisted when execution is blocked
  /// by generic loop policy (for example repetition protection).
  func blockedToolResult(for call: ToolCall) -> ToolResult

  /// Append supplementary text to a tool result.
  ///
  /// Used by the loop to inject repetition warnings into results
  /// without knowing the concrete result type.
  func appendText(_ text: String, to result: ToolResult) -> ToolResult

  /// Save a tool result into the in-memory state.
  func persistToolResult(
    _ result: ToolResult,
    for call: ToolCall,
    state: inout State,
  )

  // MARK: Compaction

  /// Whether compaction should run after this inference.
  func shouldCompact(state: State) -> Bool

  /// Perform compaction and return the next in-memory state.
  func performCompaction(state: State) async throws -> State

  // MARK: Cold Start

  /// Whether the loaded state has pending work.
  func hasWork(state: State) -> Bool

  /// Whether the transcript is mid-turn and needs an inference call.
  ///
  /// Called at the top of ``AgentLoop/runUntilIdle()`` to detect a
  /// state where the transcript ends with a tool result (or user
  /// message) that the model has not yet responded to. This happens
  /// when a prior inference attempt failed (e.g., HTTP 500 from a
  /// transient API error) and the loop restarted.
  ///
  /// When this returns `true`, the loop skips the "is there new work
  /// to drain?" check and proceeds directly to inference.
  ///
  /// Default implementation returns `false`.
  func needsInference(state: State) -> Bool
}

// MARK: - Default Implementations

public extension AgentBehavior {
  func needsInference(state _: State) -> Bool {
    false
  }
}

// MARK: - Tool Call Status

/// Status of a tool call in the execution lifecycle.
public enum ToolCallStatus: String, Sendable, Hashable, Codable {
  case pending
  case started
  case completed
  case errored
}

// MARK: - Stream Sink

/// Push-based sink for streaming inference deltas into the loop's
/// event stream.
///
/// The behavior yields stream actions during inference. The loop
/// forwards them as ``AgentLoopEvent/streamDelta(_:)`` events to
/// observers.
public struct AgentStreamSink<Action: Sendable>: Sendable {
  public let yield: @Sendable (Action) -> Void

  public init(yield: @escaping @Sendable (Action) -> Void) {
    self.yield = yield
  }
}

// MARK: - Observation

/// Gap-free observation of the agent loop's current published state.
///
/// Observers see one coherent snapshot containing the latest published state
/// plus any currently active inference deltas that belong to the same
/// published inference epoch.
public struct AgentLoopObservedState<State: Sendable, StreamAction: Sendable>: Sendable {
  /// Latest published session state.
  public var state: State

  /// Active inference identifier if streaming is in progress.
  public var inflightID: UUID?

  /// Accumulated stream deltas for the active inference, nil otherwise.
  public var inflight: [StreamAction]?

  public init(
    state: State,
    inflightID: UUID?,
    inflight: [StreamAction]?,
  ) {
    self.state = state
    self.inflightID = inflightID
    self.inflight = inflight
  }
}

public typealias AgentLoopObservation<State: Sendable, StreamAction: Sendable> =
  AnyAsyncSequence<AgentLoopObservedState<State, StreamAction>>
