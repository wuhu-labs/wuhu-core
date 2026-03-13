import Foundation
import WuhuAPI

public actor RunnerServerHandler {
  private let runner: any Runner
  public let runnerName: String

  public init(runner: any Runner, name: String) {
    self.runner = runner
    runnerName = name
  }

  public func handle(request: RunnerRequest) async -> (response: RunnerResponse, binaryData: Data?) {
    switch request {
    case let .hello(p):
      _ = p
      return (.hello(HelloResponse(runnerName: runnerName, version: muxRunnerProtocolVersion)), nil)

    case let .startBash(id, p):
      do {
        let result = try await runner.startBash(tag: p.tag, command: p.command, cwd: p.cwd, timeout: p.timeout)
        return (.startBash(id: id, .success(result)), nil)
      } catch {
        return (.startBash(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .cancelBash(id, p):
      do {
        let result = try await runner.cancelBash(tag: p.tag)
        return (.cancelBash(id: id, .success(result)), nil)
      } catch {
        return (.cancelBash(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .read(id, p):
      do {
        if p.binary {
          let data = try await runner.readData(path: p.path)
          return (.read(id: id, .success(ReadResponse(size: data.count))), data)
        } else {
          let content = try await runner.readString(path: p.path, encoding: .utf8)
          return (.read(id: id, .success(ReadResponse(content: content, size: content.utf8.count))), nil)
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
        return try await (.exists(id: id, .success(ExistsResponse(existence: runner.exists(path: p.path)))), nil)
      } catch {
        return (.exists(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .ls(id, p):
      do {
        return try await (.ls(id: id, .success(LsResponse(entries: runner.listDirectory(path: p.path)))), nil)
      } catch {
        return (.ls(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .enumerate(id, p):
      do {
        return try await (.enumerate(id: id, .success(EnumerateResponse(entries: runner.enumerateDirectory(root: p.root)))), nil)
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
        return try await (.find(id: id, .success(runner.find(params: p))), nil)
      } catch {
        return (.find(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .grep(id, p):
      do {
        return try await (.grep(id: id, .success(runner.grep(params: p))), nil)
      } catch {
        return (.grep(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }

    case let .materialize(id, p):
      do {
        return try await (.materialize(id: id, .success(runner.materialize(params: p))), nil)
      } catch {
        return (.materialize(id: id, .failure(RunnerWireError(String(describing: error)))), nil)
      }
    }
  }

  public func handleBinaryWrite(id: String, path: String, data: Data, createDirs: Bool) async -> RunnerResponse {
    do {
      try await runner.writeData(path: path, data: data, createIntermediateDirectories: createDirs)
      return .write(id: id, .success(WriteResponse(bytesWritten: data.count)))
    } catch {
      return .write(id: id, .failure(RunnerWireError(String(describing: error))))
    }
  }
}
