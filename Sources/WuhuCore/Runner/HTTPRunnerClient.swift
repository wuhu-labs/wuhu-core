import Fetch
import FetchSSE
import Foundation
import WuhuAPI
import WuhuCoreClient

public struct HTTPRunnerClient: Sendable {
  public var runnerID: RunnerID {
    .remote(name: runnerName)
  }

  public let runnerName: String

  private let baseURL: URL
  private let basePath: String?
  private let fetch: FetchClient

  public init(
    baseURL: URL,
    name: String? = nil,
    basePath: String? = nil,
    fetch: FetchClient = sharedFetchClient,
  ) {
    self.baseURL = baseURL
    self.basePath = basePath
    self.fetch = fetch

    let resolvedName = name ?? baseURL.host ?? "http-runner"
    runnerName = resolvedName
  }

  public func read(
    path: String,
    offset: Int? = nil,
    limit: Int? = nil,
  ) async throws -> HTTPRunnerV1.ReadResponse {
    try await postJSON(
      endpoint: "/v1/fs/read",
      payload: HTTPRunnerV1.ReadRequest(
        path: path,
        basePath: basePath,
        offset: offset,
        limit: limit,
      ),
      as: HTTPRunnerV1.ReadResponse.self,
    )
  }

  public func readText(
    path: String,
    offset: Int? = nil,
    limit: Int? = nil,
  ) async throws -> String {
    try await read(path: path, offset: offset, limit: limit).content
  }

  public func write(
    path: String,
    content: String,
    createDirectories: Bool = true,
  ) async throws -> HTTPRunnerV1.WriteResponse {
    try await postJSON(
      endpoint: "/v1/fs/write",
      payload: HTTPRunnerV1.WriteRequest(
        path: path,
        basePath: basePath,
        content: content,
        createDirectories: createDirectories,
      ),
      as: HTTPRunnerV1.WriteResponse.self,
    )
  }

  public func writeText(
    path: String,
    content: String,
    createDirectories: Bool = true,
  ) async throws {
    _ = try await write(
      path: path,
      content: content,
      createDirectories: createDirectories,
    )
  }

  public func list(
    path: String? = nil,
    limit: Int? = nil,
  ) async throws -> HTTPRunnerV1.LsResponse {
    try await postJSON(
      endpoint: "/v1/fs/ls",
      payload: HTTPRunnerV1.LsRequest(
        path: path,
        basePath: basePath,
        limit: limit,
      ),
      as: HTTPRunnerV1.LsResponse.self,
    )
  }

  public func listDirectory(
    path: String,
    limit: Int? = nil,
  ) async throws -> [DirectoryEntry] {
    try await list(path: path, limit: limit).entries
  }

  public func edit(
    path: String,
    oldText: String,
    newText: String,
  ) async throws -> HTTPRunnerV1.EditResponse {
    try await postJSON(
      endpoint: "/v1/fs/edit",
      payload: HTTPRunnerV1.EditRequest(
        path: path,
        basePath: basePath,
        oldText: oldText,
        newText: newText,
      ),
      as: HTTPRunnerV1.EditResponse.self,
    )
  }

  public func startBash(
    taskID: String,
    command: String,
    cwd: String,
    timeout: TimeInterval?,
  ) async throws {
    _ = try await postJSON(
      endpoint: "/v1/bash/start",
      payload: HTTPRunnerV1.BashStartRequest(
        taskID: taskID,
        command: command,
        cwd: cwd,
        timeout: timeout,
      ),
      as: HTTPRunnerV1.BashStartResponse.self,
    )
  }

  public func streamBash(
    taskID: String,
    after cursor: BashStreamCursor? = nil,
  ) async throws -> AsyncThrowingStream<BashStreamEvent, Error> {
    var request = try Request(
      url: endpointURL("/v1/bash/stream"),
      method: .post,
    )
    request.body = try Body.json(
      HTTPRunnerV1.BashStreamRequest(taskID: taskID, after: cursor),
      encoder: WuhuJSON.encoder,
    )
    request.setHeader("application/json", for: "Content-Type")
    request.setHeader("text/event-stream", for: "Accept")

    let response = try await fetch(request)
    try await Self.validate(response)

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await message in response.sse() {
            guard let data = message.data.data(using: .utf8) else { continue }
            let event = try WuhuJSON.decoder.decode(BashStreamEvent.self, from: data)
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func ackBash(taskID: String, through cursor: BashStreamCursor) async throws {
    _ = try await postJSON(
      endpoint: "/v1/bash/ack",
      payload: HTTPRunnerV1.BashAckRequest(taskID: taskID, through: cursor),
      as: HTTPRunnerV1.BashAckResponse.self,
    )
  }

  public func killBash(taskID: String) async throws {
    _ = try await postJSON(
      endpoint: "/v1/bash/kill",
      payload: HTTPRunnerV1.BashKillRequest(taskID: taskID),
      as: HTTPRunnerV1.BashKillResponse.self,
    )
  }

  public func runnerHandle() -> RunnerHandle {
    let client = self
    return RunnerHandle(
      id: runnerID,
      readText: { path in
        try await client.readText(path: path)
      },
      readData: { _ in
        throw Self.unsupported("readData")
      },
      writeText: { path, content, createDirs in
        try await client.writeText(path: path, content: content, createDirectories: createDirs)
      },
      writeData: { _, _, _ in
        throw Self.unsupported("writeData")
      },
      listDirectory: { path in
        try await client.listDirectory(path: path)
      },
      find: { _ in
        throw Self.unsupported("find")
      },
      grep: { _ in
        throw Self.unsupported("grep")
      },
      startBash: { taskID, cwd, command, timeout in
        try await client.startBash(taskID: taskID, command: command, cwd: cwd, timeout: timeout)
      },
      streamBash: { taskID, after in
        try await client.streamBash(taskID: taskID, after: after)
      },
      ackBash: { taskID, through in
        try await client.ackBash(taskID: taskID, through: through)
      },
      killBash: { taskID in
        try await client.killBash(taskID: taskID)
      },
      runBash: { cwd, command, timeout in
        let taskID = UUID().uuidString.lowercased()
        try await client.startBash(taskID: taskID, command: command, cwd: cwd, timeout: timeout)
        let stream = try await client.streamBash(taskID: taskID, after: nil)
        for try await event in stream {
          try await client.ackBash(taskID: taskID, through: event.cursor)
          if case let .finished(result) = event.payload {
            return result
          }
        }
        throw RunnerError.requestFailed(message: "Bash stream ended without a terminal result")
      },
    )
  }

  private func postJSON<ResponseBody: Decodable & Sendable>(
    endpoint: String,
    payload: some Encodable & Sendable,
    as _: ResponseBody.Type,
  ) async throws -> ResponseBody {
    var request = try Request(
      url: endpointURL(endpoint),
      method: .post,
    )
    request.body = try Body.json(payload, encoder: WuhuJSON.encoder)

    let response = try await fetch(request)
    try await Self.validate(response)

    return try await response.body.json(ResponseBody.self, decoder: WuhuJSON.decoder)
  }

  private func endpointURL(_ endpoint: String) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw RunnerError.requestFailed(message: "Invalid runner base URL: \(baseURL.absoluteString)")
    }

    let normalizedEndpoint = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
    let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
    components.path = basePath + normalizedEndpoint

    guard let url = components.url else {
      throw RunnerError.requestFailed(message: "Could not construct runner endpoint for \(endpoint)")
    }
    return url
  }

  private static func unsupported(_ operation: String) -> RunnerError {
    RunnerError.requestFailed(message: "HTTP runner v1 does not support \(operation)")
  }

  private static func validate(_ response: Response) async throws {
    guard (200 ..< 300).contains(response.status.code) else {
      if let errorResponse = try? await response.body.json(HTTPRunnerV1.ErrorResponse.self, decoder: WuhuJSON.decoder) {
        throw RunnerError.requestFailed(message: errorResponse.error.message)
      }
      let text = await (try? response.text()) ?? "HTTP \(response.status.code)"
      throw RunnerError.requestFailed(message: text)
    }
  }
}
