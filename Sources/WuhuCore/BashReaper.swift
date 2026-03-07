import Foundation

/// Lightweight service that dispatches kill requests to runners.
///
/// When a tool call task is cancelled (e.g., user presses stop), the caller
/// enqueues a kill request with the reaper rather than blocking on the signal
/// delivery. The reaper asynchronously sends the `MuxRunnerOp.cancel` RPC to
/// the appropriate runner.
///
/// This means stop is fast — the UI gets a response immediately. The reaper
/// handles the messy part (sending the signal, retrying if the runner is slow).
public actor BashReaper {
  /// A pending kill request.
  public struct KillRequest: Sendable {
    public var runnerName: String
    public var processGroupID: Int32

    public init(runnerName: String, processGroupID: Int32) {
      self.runnerName = runnerName
      self.processGroupID = processGroupID
    }
  }

  private let runnerRegistry: RunnerRegistry
  private var pending: [KillRequest] = []
  private var drainTask: Task<Void, Never>?

  public init(runnerRegistry: RunnerRegistry) {
    self.runnerRegistry = runnerRegistry
  }

  /// Enqueue a kill request. Returns immediately.
  public func enqueue(_ request: KillRequest) {
    pending.append(request)
    ensureDraining()
  }

  private func ensureDraining() {
    guard drainTask == nil else { return }
    drainTask = Task {
      while true {
        let batch = await takePending()
        if batch.isEmpty { break }
        for request in batch {
          await dispatch(request)
        }
      }
      await clearDrainTask()
    }
  }

  private func takePending() -> [KillRequest] {
    let batch = pending
    pending = []
    return batch
  }

  private func clearDrainTask() {
    drainTask = nil
    // Check if more requests arrived while we were dispatching
    if !pending.isEmpty {
      ensureDraining()
    }
  }

  private func dispatch(_ request: KillRequest) async {
    // Look up the runner. For local runner, it's registered as "local".
    guard let runner = await runnerRegistry.get(name: request.runnerName) else {
      let line = "[BashReaper] WARNING: runner '\(request.runnerName)' not found for kill request (pgid=\(request.processGroupID))\n"
      FileHandle.standardError.write(Data(line.utf8))
      return
    }

    // If it's a MuxRunnerClient, send the cancel RPC
    if let muxClient = runner as? MuxRunnerClient {
      do {
        _ = try await muxClient.cancel(processGroupID: request.processGroupID)
      } catch {
        let line = "[BashReaper] WARNING: cancel RPC to '\(request.runnerName)' failed: \(error)\n"
        FileHandle.standardError.write(Data(line.utf8))
      }
    } else {
      // Shouldn't happen in production since all runners are now MuxRunnerClient,
      // but handle gracefully for tests
      let line = "[BashReaper] WARNING: runner '\(request.runnerName)' is not a MuxRunnerClient, cannot send cancel\n"
      FileHandle.standardError.write(Data(line.utf8))
    }
  }
}
