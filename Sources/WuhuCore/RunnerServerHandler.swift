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

  /// Dispatch a request to the wrapped runner and return a response.
  public func handle(request: RunnerRequest) async -> RunnerResponse {
    switch request {
    case .hello:
      // Server said hello; we respond with our hello.
      return .hello(runnerName: runnerName, version: runnerProtocolVersion)

    case let .bash(id, command, cwd, timeout):
      do {
        let result = try await runner.runBash(command: command, cwd: cwd, timeout: timeout)
        return .bash(id: id, result: result, error: nil)
      } catch {
        return .bash(id: id, result: nil, error: String(describing: error))
      }

    case let .readFile(id, path):
      do {
        let data = try await runner.readData(path: path)
        return .readFile(id: id, base64Data: data.base64EncodedString(), error: nil)
      } catch {
        return .readFile(id: id, base64Data: nil, error: String(describing: error))
      }

    case let .readString(id, path):
      do {
        let content = try await runner.readString(path: path, encoding: .utf8)
        return .readString(id: id, content: content, error: nil)
      } catch {
        return .readString(id: id, content: nil, error: String(describing: error))
      }

    case let .writeFile(id, path, base64Data, createDirs):
      do {
        guard let data = Data(base64Encoded: base64Data) else {
          return .writeFile(id: id, error: "Invalid base64 data")
        }
        try await runner.writeData(path: path, data: data, createIntermediateDirectories: createDirs)
        return .writeFile(id: id, error: nil)
      } catch {
        return .writeFile(id: id, error: String(describing: error))
      }

    case let .writeString(id, path, content, createDirs):
      do {
        try await runner.writeString(path: path, content: content, createIntermediateDirectories: createDirs, encoding: .utf8)
        return .writeString(id: id, error: nil)
      } catch {
        return .writeString(id: id, error: String(describing: error))
      }

    case let .exists(id, path):
      do {
        let existence = try await runner.exists(path: path)
        return .exists(id: id, existence: existence, error: nil)
      } catch {
        return .exists(id: id, existence: nil, error: String(describing: error))
      }

    case let .listDirectory(id, path):
      do {
        let entries = try await runner.listDirectory(path: path)
        return .listDirectory(id: id, entries: entries, error: nil)
      } catch {
        return .listDirectory(id: id, entries: nil, error: String(describing: error))
      }

    case let .enumerateDirectory(id, root):
      do {
        let entries = try await runner.enumerateDirectory(root: root)
        return .enumerateDirectory(id: id, entries: entries, error: nil)
      } catch {
        return .enumerateDirectory(id: id, entries: nil, error: String(describing: error))
      }

    case let .createDirectory(id, path, withIntermediateDirectories):
      do {
        try await runner.createDirectory(path: path, withIntermediateDirectories: withIntermediateDirectories)
        return .createDirectory(id: id, error: nil)
      } catch {
        return .createDirectory(id: id, error: String(describing: error))
      }
    }
  }
}
