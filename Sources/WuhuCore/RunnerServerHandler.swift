import Foundation
import WuhuAPI

/// Wraps any `Runner` and dispatches incoming `RunnerRequest` messages to it.
///
/// This is the runner-side handler: a runner process creates a `LocalRunner`,
/// wraps it in a `RunnerServerHandler`, and uses it to handle WebSocket messages.
/// The handler is also usable for in-process testing (no network needed).
public actor RunnerServerHandler {
  private let runner: any Runner
  public let runnerName: String

  /// Active bash tasks keyed by their cancel tag.
  /// When a cancel request arrives, we look up the task and cancel it,
  /// which triggers the swift-subprocess teardownSequence (SIGTERM → 3s → SIGKILL).
  private var activeBashTasks: [String: Task<(RunnerResponse, Data?), Never>] = [:]

  public init(runner: any Runner, name: String) {
    self.runner = runner
    runnerName = name
  }

  /// Run a bash request, tracking it by tag for cancellation.
  /// If the request has a tag, the task is stored in `activeBashTasks`
  /// and removed when it completes (or is cancelled).
  public func runBash(id: String, request: BashRequest) async -> (RunnerResponse, Data?) {
    do {
      let result = try await runner.runBash(command: request.command, cwd: request.cwd, timeout: request.timeout)
      return (.bash(id: id, .success(result)), nil)
    } catch is CancellationError {
      return (.bash(id: id, .success(BashResult(exitCode: -15, output: "", timedOut: false, terminated: true))), nil)
    } catch {
      return (.bash(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
    }
  }

  /// Register an active bash task for cancellation tracking.
  public func registerBashTask(_ tag: String, task: Task<(RunnerResponse, Data?), Never>) {
    activeBashTasks[tag] = task
  }

  /// Unregister a completed bash task.
  public func unregisterBashTask(_ tag: String) {
    activeBashTasks.removeValue(forKey: tag)
  }

  /// Cancel a bash task by tag. Cancels the Swift task, which triggers
  /// the swift-subprocess teardownSequence (SIGTERM → 3s → SIGKILL).
  public func cancelBash(tag: String) -> Bool {
    guard let task = activeBashTasks.removeValue(forKey: tag) else {
      return false
    }
    task.cancel()
    return true
  }

  /// Dispatch a text-frame request. Returns a text-frame response.
  /// For binary data, also returns optional companion data to send as a binary frame.
  ///
  /// Note: bash requests should use `runBash(id:request:)` directly through
  /// `MuxRunnerHandler` so they can be tracked for cancellation. This method
  /// still handles bash for backward compatibility (e.g., tests).
  public func handle(request: RunnerRequest) async -> (RunnerResponse, Data?) {
    switch request {
    case let .hello(p):
      _ = p // acknowledge
      return (.hello(HelloResponse(runnerName: runnerName, version: muxRunnerProtocolVersion)), nil)

    case let .bash(id, p):
      return await runBash(id: id, request: p)

    case let .read(id, p):
      do {
        if p.binary {
          let data = try await runner.readData(path: p.path)
          let resp = ReadResponse(size: data.count)
          return (.read(id: id, .success(resp)), data)
        } else {
          let content = try await runner.readString(path: p.path, encoding: .utf8)
          let resp = ReadResponse(content: content, size: content.utf8.count)
          return (.read(id: id, .success(resp)), nil)
        }
      } catch {
        return (.read(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .write(id, p):
      do {
        if let content = p.content {
          try await runner.writeString(path: p.path, content: content, createIntermediateDirectories: p.createDirs, encoding: .utf8)
          return (.write(id: id, .success(WriteResponse(bytesWritten: content.utf8.count))), nil)
        } else {
          return (.write(id: id, .failure(RunnerWireError("Binary write requires companion binary frame"))), nil)
        }
      } catch {
        return (.write(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .exists(id, p):
      do {
        let existence = try await runner.exists(path: p.path)
        return (.exists(id: id, .success(ExistsResponse(existence: existence))), nil)
      } catch {
        return (.exists(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .ls(id, p):
      do {
        let entries = try await runner.listDirectory(path: p.path)
        return (.ls(id: id, .success(LsResponse(entries: entries))), nil)
      } catch {
        return (.ls(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .enumerate(id, p):
      do {
        let entries = try await runner.enumerateDirectory(root: p.root)
        return (.enumerate(id: id, .success(EnumerateResponse(entries: entries))), nil)
      } catch {
        return (.enumerate(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .mkdir(id, p):
      do {
        try await runner.createDirectory(path: p.path, withIntermediateDirectories: p.recursive)
        return (.mkdir(id: id, .success(MkdirResponse())), nil)
      } catch {
        return (.mkdir(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .find(id, p):
      do {
        let result = try await runner.find(params: p)
        return (.find(id: id, .success(result)), nil)
      } catch {
        return (.find(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .grep(id, p):
      do {
        let result = try await runner.grep(params: p)
        return (.grep(id: id, .success(result)), nil)
      } catch {
        return (.grep(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .materialize(id, p):
      do {
        let result = try await runner.materialize(params: p)
        return (.materialize(id: id, .success(result)), nil)
      } catch {
        return (.materialize(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .cancel(id, p):
      let found = cancelBash(tag: p.tag)
      return (.cancel(id: id, .success(CancelResponse(cancelled: found))), nil)
    }
  }

  /// Handle a binary write: data arrived in a binary frame for a pending write request.
  public func handleBinaryWrite(id: String, path: String, data: Data, createDirs: Bool) async -> RunnerResponse {
    do {
      try await runner.writeData(path: path, data: data, createIntermediateDirectories: createDirs)
      return .write(id: id, .success(WriteResponse(bytesWritten: data.count)))
    } catch {
      return .write(id: id, .failure(RunnerWireError(String(describing: error))))
    }
  }
}
