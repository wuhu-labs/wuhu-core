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

  public init(runner: any Runner, name: String) {
    self.runner = runner
    runnerName = name
  }

  /// Dispatch a text-frame request. Returns a text-frame response.
  /// For binary data, also returns optional companion data to send as a binary frame.
  public func handle(request: RunnerRequest) async -> (response: RunnerResponse, binaryData: Data?) {
    switch request {
    case let .hello(p):
      _ = p // acknowledge
      return (.hello(HelloResponse(runnerName: runnerName, version: runnerProtocolVersion)), nil)

    case let .bash(id, p):
      do {
        let result = try await runner.runBash(command: p.command, cwd: p.cwd, timeout: p.timeout)
        return (.bash(id: id, .success(result)), nil)
      } catch {
        return (.bash(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

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
          // Text write — content is in the JSON payload
          try await runner.writeString(path: p.path, content: content, createIntermediateDirectories: p.createDirs, encoding: .utf8)
          return (.write(id: id, .success(WriteResponse(bytesWritten: content.utf8.count))), nil)
        } else {
          // Binary write — data will be delivered separately via handleBinaryWrite.
          // Return a pending response; the actual write happens in handleBinaryWrite.
          // For the handler-only path (no network), this shouldn't happen.
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
