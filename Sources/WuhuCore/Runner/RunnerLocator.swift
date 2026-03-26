import Dependencies
import Foundation
import WuhuAPI

public struct RunnerHandle: Sendable {
  public var id: RunnerID
  public var readText: @Sendable (_ path: String) async throws -> String
  public var readData: @Sendable (_ path: String) async throws -> Data
  public var writeText: @Sendable (_ path: String, _ content: String, _ createDirs: Bool) async throws -> Void
  public var writeData: @Sendable (_ path: String, _ data: Data, _ createDirs: Bool) async throws -> Void
  public var listDirectory: @Sendable (_ path: String) async throws -> [DirectoryEntry]
  public var find: @Sendable (_ params: FindParams) async throws -> FindResult
  public var grep: @Sendable (_ params: GrepParams) async throws -> GrepResult
  public var runBash: @Sendable (_ cwd: String, _ command: String, _ timeout: TimeInterval?) async throws -> BashResult

  public init(
    id: RunnerID,
    readText: @escaping @Sendable (_ path: String) async throws -> String,
    readData: @escaping @Sendable (_ path: String) async throws -> Data,
    writeText: @escaping @Sendable (_ path: String, _ content: String, _ createDirs: Bool) async throws -> Void,
    writeData: @escaping @Sendable (_ path: String, _ data: Data, _ createDirs: Bool) async throws -> Void,
    listDirectory: @escaping @Sendable (_ path: String) async throws -> [DirectoryEntry],
    find: @escaping @Sendable (_ params: FindParams) async throws -> FindResult,
    grep: @escaping @Sendable (_ params: GrepParams) async throws -> GrepResult,
    runBash: @escaping @Sendable (_ cwd: String, _ command: String, _ timeout: TimeInterval?) async throws -> BashResult,
  ) {
    self.id = id
    self.readText = readText
    self.readData = readData
    self.writeText = writeText
    self.writeData = writeData
    self.listDirectory = listDirectory
    self.find = find
    self.grep = grep
    self.runBash = runBash
  }
}

public struct RunnerLocator: Sendable {
  public var resolve: @Sendable (_ runnerID: RunnerID) async throws -> RunnerHandle

  public init(resolve: @escaping @Sendable (_ runnerID: RunnerID) async throws -> RunnerHandle) {
    self.resolve = resolve
  }
}

public extension RunnerLocator {
  static func live(registry: RunnerRegistry) -> Self {
    .init { runnerID in
      guard let runner = await registry.get(runnerID) else {
        throw MountResolutionError.runnerUnavailable(runnerID: runnerID)
      }
      return RunnerHandle(
        id: runner.id,
        readText: { path in try await runner.readString(path: path, encoding: .utf8) },
        readData: { path in try await runner.readData(path: path) },
        writeText: { path, content, createDirs in
          try await runner.writeString(path: path, content: content, createIntermediateDirectories: createDirs, encoding: .utf8)
        },
        writeData: { path, data, createDirs in
          try await runner.writeData(path: path, data: data, createIntermediateDirectories: createDirs)
        },
        listDirectory: { path in try await runner.listDirectory(path: path) },
        find: { params in try await runner.find(params: params) },
        grep: { params in try await runner.grep(params: params) },
        runBash: { cwd, command, timeout in
          try await runner.runBash(command: command, cwd: cwd, timeout: timeout)
        },
      )
    }
  }

  static let localOnly = Self { runnerID in
    guard runnerID == .local else {
      throw MountResolutionError.runnerUnavailable(runnerID: runnerID)
    }
    let runner = LocalRunner()
    return RunnerHandle(
      id: .local,
      readText: { path in try await runner.readString(path: path, encoding: .utf8) },
      readData: { path in try await runner.readData(path: path) },
      writeText: { path, content, createDirs in
        try await runner.writeString(path: path, content: content, createIntermediateDirectories: createDirs, encoding: .utf8)
      },
      writeData: { path, data, createDirs in
        try await runner.writeData(path: path, data: data, createIntermediateDirectories: createDirs)
      },
      listDirectory: { path in try await runner.listDirectory(path: path) },
      find: { params in try await runner.find(params: params) },
      grep: { params in try await runner.grep(params: params) },
      runBash: { cwd, command, timeout in
        try await runner.runBash(command: command, cwd: cwd, timeout: timeout)
      },
    )
  }
}

private enum RunnerLocatorKey: DependencyKey {
  static let liveValue = RunnerLocator.localOnly
  static let testValue = RunnerLocator.localOnly
}

public extension DependencyValues {
  var runnerLocator: RunnerLocator {
    get { self[RunnerLocatorKey.self] }
    set { self[RunnerLocatorKey.self] = newValue }
  }
}
