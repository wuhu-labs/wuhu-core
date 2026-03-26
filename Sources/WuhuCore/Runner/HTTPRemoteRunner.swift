import Fetch
import Foundation
import WuhuAPI

public actor HTTPRemoteRunner: Runner {
  public nonisolated let id: RunnerID

  private let client: HTTPRunnerClient

  public init(
    baseURL: URL,
    name: String? = nil,
    basePath: String? = nil,
    fetch: FetchClient = sharedFetchClient,
  ) {
    let client = HTTPRunnerClient(
      baseURL: baseURL,
      name: name,
      basePath: basePath,
      fetch: fetch,
    )
    self.client = client
    id = client.runnerID
  }

  public func startBash(taskID: String, command: String, cwd: String, timeout: TimeInterval?) async throws {
    try await client.startBash(taskID: taskID, command: command, cwd: cwd, timeout: timeout)
  }

  public func streamBash(taskID: String, after cursor: BashStreamCursor?) async throws -> AsyncThrowingStream<BashStreamEvent, any Error> {
    try await client.streamBash(taskID: taskID, after: cursor)
  }

  public func ackBash(taskID: String, through cursor: BashStreamCursor) async throws {
    try await client.ackBash(taskID: taskID, through: cursor)
  }

  public func killBash(taskID: String) async throws {
    try await client.killBash(taskID: taskID)
  }

  public func readData(path _: String) async throws -> Data {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support readData")
  }

  public func readString(path: String, encoding _: String.Encoding) async throws -> String {
    try await client.readText(path: path)
  }

  public func writeData(path _: String, data _: Data, createIntermediateDirectories _: Bool) async throws {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support writeData")
  }

  public func writeString(
    path: String,
    content: String,
    createIntermediateDirectories: Bool,
    encoding _: String.Encoding,
  ) async throws {
    try await client.writeText(
      path: path,
      content: content,
      createDirectories: createIntermediateDirectories,
    )
  }

  public func exists(path _: String) async throws -> FileExistence {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support exists")
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    try await client.listDirectory(path: path)
  }

  public func enumerateDirectory(root _: String) async throws -> [EnumeratedEntry] {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support enumerateDirectory")
  }

  public func createDirectory(path _: String, withIntermediateDirectories _: Bool) async throws {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support createDirectory")
  }

  public func find(params _: FindParams) async throws -> FindResult {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support find")
  }

  public func grep(params _: GrepParams) async throws -> GrepResult {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support grep")
  }

  public func materialize(params _: MaterializeRequest) async throws -> MaterializeResponse {
    throw RunnerError.requestFailed(message: "HTTP runner v1 does not support materialize")
  }
}
