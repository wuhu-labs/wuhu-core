import Foundation
import Logging

/// Dispatches bash kill requests to runners.
///
/// When the agent loop's tool call task is cancelled (e.g., user presses stop),
/// a `withTaskCancellationHandler` enqueues a kill request here. The reaper
/// then asynchronously sends the cancel RPC to the appropriate runner.
///
/// This design means **stop is fast** — the agent loop returns immediately
/// without waiting for the bash process to actually die. The reaper handles
/// the messy part (sending the cancel op, retrying if needed).
public actor BashReaper {
  private let runnerRegistry: RunnerRegistry
  private let logger: Logger

  public init(runnerRegistry: RunnerRegistry, logger: Logger = Logger(label: "BashReaper")) {
    self.runnerRegistry = runnerRegistry
    self.logger = logger
  }

  /// Enqueue a kill request. Called from `withTaskCancellationHandler` when
  /// a bash tool call's parent task is cancelled.
  ///
  /// This is nonisolated so it can be called synchronously from a cancellation
  /// handler (which runs synchronously on the cancelled task's thread).
  public nonisolated func enqueueKill(runnerID: RunnerID, tag: String) {
    Task {
      await self.dispatchKill(runnerID: runnerID, tag: tag)
    }
  }

  /// Send the cancel RPC to the runner.
  private func dispatchKill(runnerID: RunnerID, tag: String) async {
    guard let runner = await runnerRegistry.get(runnerID) else {
      logger.warning("BashReaper: runner '\(runnerID.displayName)' not found, cannot cancel tag=\(tag)")
      return
    }

    guard let muxClient = runner as? MuxRunnerClient else {
      logger.warning("BashReaper: runner '\(runnerID.displayName)' is not a MuxRunnerClient, cannot cancel tag=\(tag)")
      return
    }

    do {
      let response = try await muxClient.cancel(tag: tag)
      if response.cancelled {
        logger.info("BashReaper: cancelled tag=\(tag) on runner '\(runnerID.displayName)'")
      } else {
        logger.info("BashReaper: tag=\(tag) not found on runner '\(runnerID.displayName)' (may have already finished)")
      }
    } catch {
      logger.error("BashReaper: failed to cancel tag=\(tag) on runner '\(runnerID.displayName)': \(error)")
    }
  }
}
