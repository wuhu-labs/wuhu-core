import Fetch
import Foundation
import WuhuAPI

public actor HTTPRunnerClient: Runner {
  public nonisolated let id: RunnerID
  public let runnerName: String

  private let baseURL: URL
  private let basePath: String?
  private let fetch: FetchClient

  public init(
    baseURL: URL,
    name: String? = nil,
    basePath: String? = nil,
    fetch: FetchClient = sharedFetchClient
  ) {
    self.baseURL = baseURL
    self.basePath = basePath
    self.fetch = fetch

    let resolvedName = name ?? baseURL.host ?? "http-runner"
    runnerName = resolvedName
    id = .remote(name: resolvedName)
  }

  public func read(
    path: String,
    offset: Int? = nil,
    limit: Int? = nil
  ) async throws -> HTTPRunnerV1.ReadResponse {
    try await self.postJSON(
      endpoint: "/v1/fs/read",
      payload: HTTPRunnerV1.ReadRequest(
        path: path,
        basePath: self.basePath,
        offset: offset,
        limit: limit
      ),
      as: HTTPRunnerV1.ReadResponse.self
    )
  }

  public func write(
    path: String,
    content: String,
    createDirectories: Bool = true
  ) async throws -> HTTPRunnerV1.WriteResponse {
    try await self.postJSON(
      endpoint: "/v1/fs/write",
      payload: HTTPRunnerV1.WriteRequest(
        path: path,
        basePath: self.basePath,
        content: content,
        createDirectories: createDirectories
      ),
      as: HTTPRunnerV1.WriteResponse.self
    )
  }

  public func list(
    path: String? = nil,
    limit: Int? = nil
  ) async throws -> HTTPRunnerV1.LsResponse {
    try await self.postJSON(
      endpoint: "/v1/fs/ls",
      payload: HTTPRunnerV1.LsRequest(
        path: path,
        basePath: self.basePath,
        limit: limit
      ),
      as: HTTPRunnerV1.LsResponse.self
    )
  }

  public func edit(
    path: String,
    oldText: String,
    newText: String
  ) async throws -> HTTPRunnerV1.EditResponse {
    try await self.postJSON(
      endpoint: "/v1/fs/edit",
      payload: HTTPRunnerV1.EditRequest(
        path: path,
        basePath: self.basePath,
        oldText: oldText,
        newText: newText
      ),
      as: HTTPRunnerV1.EditResponse.self
    )
  }

  public func runBash(command _: String, cwd _: String, timeout _: TimeInterval?) async throws -> BashResult {
    throw Self.unsupported("bash")
  }

  public func readData(path _: String) async throws -> Data {
    throw Self.unsupported("readData")
  }

  public func readString(path: String, encoding _: String.Encoding) async throws -> String {
    try await self.read(path: path).content
  }

  public func writeData(path _: String, data _: Data, createIntermediateDirectories _: Bool) async throws {
    throw Self.unsupported("writeData")
  }

  public func writeString(
    path: String,
    content: String,
    createIntermediateDirectories: Bool,
    encoding _: String.Encoding
  ) async throws {
    _ = try await self.write(
      path: path,
      content: content,
      createDirectories: createIntermediateDirectories
    )
  }

  public func exists(path _: String) async throws -> FileExistence {
    throw Self.unsupported("exists")
  }

  public func listDirectory(path: String) async throws -> [DirectoryEntry] {
    try await self.list(path: path).entries
  }

  public func enumerateDirectory(root _: String) async throws -> [EnumeratedEntry] {
    throw Self.unsupported("enumerateDirectory")
  }

  public func createDirectory(path _: String, withIntermediateDirectories _: Bool) async throws {
    throw Self.unsupported("createDirectory")
  }

  public func find(params _: FindParams) async throws -> FindResult {
    throw Self.unsupported("find")
  }

  public func grep(params _: GrepParams) async throws -> GrepResult {
    throw Self.unsupported("grep")
  }

  public func materialize(params _: MaterializeRequest) async throws -> MaterializeResponse {
    throw Self.unsupported("materialize")
  }

  private func postJSON<ResponseBody: Decodable & Sendable>(
    endpoint: String,
    payload: some Encodable & Sendable,
    as _: ResponseBody.Type
  ) async throws -> ResponseBody {
    var request = Request(
      url: try self.endpointURL(endpoint),
      method: .post
    )
    request.body = try Body.json(payload, encoder: WuhuJSON.encoder)

    let response = try await self.fetch(request)

    guard (200 ..< 300).contains(response.status.code) else {
      if let errorResponse = try? await response.body.json(HTTPRunnerV1.ErrorResponse.self, decoder: WuhuJSON.decoder) {
        throw RunnerError.requestFailed(message: errorResponse.error.message)
      }
      let text = (try? await response.text()) ?? "HTTP \(response.status.code)"
      throw RunnerError.requestFailed(message: text)
    }

    return try await response.body.json(ResponseBody.self, decoder: WuhuJSON.decoder)
  }

  private func endpointURL(_ endpoint: String) throws -> URL {
    guard var components = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false) else {
      throw RunnerError.requestFailed(message: "Invalid runner base URL: \(self.baseURL.absoluteString)")
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
}
