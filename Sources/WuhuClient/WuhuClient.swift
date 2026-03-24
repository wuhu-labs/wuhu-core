import Foundation
import Fetch
import FetchSSE
import WuhuAI
import WuhuAPI
import WuhuCoreClient

public struct WuhuClient: Sendable {
  public var baseURL: URL
  private let fetch: FetchClient

  public enum EnqueueLane: String, Sendable, Hashable {
    case steer
    case followUp
  }

  public init(baseURL: URL, fetch: FetchClient = sharedFetchClient) {
    self.baseURL = baseURL
    self.fetch = fetch
  }

  public func listMountTemplates() async throws -> [WuhuMountTemplate] {
    let url = baseURL.appending(path: "v1").appending(path: "mount-templates")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuMountTemplate].self, from: data)
  }

  public func createMountTemplate(_ request: WuhuCreateMountTemplateRequest) async throws -> WuhuMountTemplate {
    let url = baseURL.appending(path: "v1").appending(path: "mount-templates")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(request), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuMountTemplate.self, from: data)
  }

  public func getMountTemplate(_ identifier: String) async throws -> WuhuMountTemplate {
    let url = baseURL.appending(path: "v1").appending(path: "mount-templates").appending(path: identifier)
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuMountTemplate.self, from: data)
  }

  public func updateMountTemplate(_ identifier: String, request: WuhuUpdateMountTemplateRequest) async throws -> WuhuMountTemplate {
    let url = baseURL.appending(path: "v1").appending(path: "mount-templates").appending(path: identifier)
    var req = Request(url: url, method: "PATCH")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(request), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuMountTemplate.self, from: data)
  }

  public func deleteMountTemplate(_ identifier: String) async throws {
    let url = baseURL.appending(path: "v1").appending(path: "mount-templates").appending(path: identifier)
    let req = Request(url: url, method: "DELETE")
    _ = try await responseData(for: req)
  }

  public func listWorkspaceDocs() async throws -> [WuhuWorkspaceDocSummary] {
    let url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "docs")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuWorkspaceDocSummary].self, from: data)
  }

  public func workspaceTree() async throws -> DirectoryNode {
    let url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "tree")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(DirectoryNode.self, from: data)
  }

  public func workspaceQuery(sql: String) async throws -> [[String: String]] {
    var url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "query")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "sql", value: sql)]
    url = components?.url ?? url

    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([[String: String]].self, from: data)
  }

  public func readWorkspaceDoc(path: String) async throws -> WuhuWorkspaceDoc {
    var url = baseURL.appending(path: "v1").appending(path: "workspace").appending(path: "doc")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "path", value: path)]
    url = components?.url ?? url

    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuWorkspaceDoc.self, from: data)
  }

  public func createSession(_ request: WuhuCreateSessionRequest) async throws -> WuhuSession {
    let url = baseURL.appending(path: "v1").appending(path: "sessions")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setBody(try WuhuJSON.encoder.encode(request), contentType: "application/json")

    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuSession.self, from: data)
  }

  public func renameSession(id: String, title: String) async throws -> WuhuRenameSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: id)
    var req = Request(url: url, method: "PATCH")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuRenameSessionRequest(title: title)), contentType: "application/json")

    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuRenameSessionResponse.self, from: data)
  }

  public func setSessionModel(
    sessionID: String,
    provider: WuhuProvider,
    model: String? = nil,
    reasoningEffort: ReasoningEffort? = nil,
  ) async throws -> WuhuSetSessionModelResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "model")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuSetSessionModelRequest(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
    )), contentType: "application/json")

    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuSetSessionModelResponse.self, from: data)
  }

  public func listSessions(limit: Int? = nil, includeArchived: Bool = false) async throws -> [WuhuSession] {
    var url = baseURL.appending(path: "v1").appending(path: "sessions")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []
    if let limit {
      items.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if includeArchived {
      items.append(URLQueryItem(name: "includeArchived", value: "true"))
    }
    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuSession].self, from: data)
  }

  public func getSession(
    id: String,
    sinceCursor: Int64? = nil,
    sinceTime: Date? = nil,
  ) async throws -> WuhuGetSessionResponse {
    var url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: id)
    if sinceCursor != nil || sinceTime != nil {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var items: [URLQueryItem] = []
      if let sinceCursor { items.append(.init(name: "sinceCursor", value: String(sinceCursor))) }
      if let sinceTime { items.append(.init(name: "sinceTime", value: String(sinceTime.timeIntervalSince1970))) }
      components?.queryItems = items.isEmpty ? nil : items
      url = components?.url ?? url
    }
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuGetSessionResponse.self, from: data)
  }

  public func enqueue(
    sessionID: String,
    content: MessageContent,
    user: String? = nil,
    lane: EnqueueLane = .followUp,
  ) async throws -> String {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "enqueue")

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "lane", value: lane.rawValue)]

    let author: Author = {
      let trimmed = (user ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return .unknown }
      return .participant(.init(rawValue: trimmed), kind: .human)
    }()

    let message = QueuedUserMessage(author: author, content: content)

    var req = Request(url: components?.url ?? url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(message), contentType: "application/json")

    let data = try await responseData(for: req)
    let qid = try WuhuJSON.decoder.decode(QueueItemID.self, from: data)
    return qid.rawValue
  }

  public func enqueue(
    sessionID: String,
    input: String,
    user: String? = nil,
    lane: EnqueueLane = .followUp,
  ) async throws -> String {
    try await enqueue(sessionID: sessionID, content: .text(input), user: user, lane: lane)
  }

  public func promptStream(
    sessionID: String,
    input: String,
    user: String? = nil,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    let baseline = try await getSession(id: sessionID)
    let sinceCursor = baseline.transcript.last?.id

    _ = try await enqueue(sessionID: sessionID, input: input, user: user, lane: .followUp)
    return try await followSessionStream(
      sessionID: sessionID,
      sinceCursor: sinceCursor,
      sinceTime: nil,
      stopAfterIdle: true,
      timeoutSeconds: nil,
    )
  }

  public func followSessionStream(
    sessionID: String,
    sinceCursor: Int64? = nil,
    sinceTime: Date? = nil,
    stopAfterIdle: Bool? = nil,
    timeoutSeconds: Double? = nil,
  ) async throws -> AsyncThrowingStream<WuhuSessionStreamEvent, any Error> {
    var url = baseURL.appending(path: "v1").appending(path: "sessions").appending(path: sessionID).appending(path: "follow")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []
    if let sinceCursor { items.append(.init(name: "sinceCursor", value: String(sinceCursor))) }
    if let sinceTime { items.append(.init(name: "sinceTime", value: String(sinceTime.timeIntervalSince1970))) }
    if let stopAfterIdle { items.append(.init(name: "stopAfterIdle", value: stopAfterIdle ? "1" : "0")) }
    if let timeoutSeconds { items.append(.init(name: "timeoutSeconds", value: String(timeoutSeconds))) }
    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    var req = Request(url: url, method: "GET")
    req.setHeader("text/event-stream", for: "Accept")
    let response = try await fetch(req)
    try response.validateStatus()
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await message in response.sse() {
            guard let data = message.data.data(using: .utf8) else { continue }
            let event = try WuhuJSON.decoder.decode(WuhuSessionStreamEvent.self, from: data)
            continuation.yield(event)
            if case .done = event { break }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func archiveSession(sessionID: String) async throws -> WuhuArchiveSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "archive")
    let req = Request(url: url, method: "POST")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuArchiveSessionResponse.self, from: data)
  }

  public func unarchiveSession(sessionID: String) async throws -> WuhuArchiveSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "unarchive")
    let req = Request(url: url, method: "POST")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuArchiveSessionResponse.self, from: data)
  }

  public func stopSession(
    sessionID: String,
    user: String? = nil,
  ) async throws -> WuhuStopSessionResponse {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "stop")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuStopSessionRequest(user: user)), contentType: "application/json")

    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuStopSessionResponse.self, from: data)
  }

  /// Upload binary data as a blob and return the blob URI.
  public func uploadBlob(sessionID: String, data: Data, mimeType: String) async throws -> String {
    let url = baseURL
      .appending(path: "v1")
      .appending(path: "sessions")
      .appending(path: sessionID)
      .appending(path: "blobs")
    var req = Request(url: url, method: "POST")
    req.setHeader(mimeType, for: "Content-Type")
    req.setBody(data, contentType: mimeType)

    let responseData = try await responseData(for: req)
    struct BlobResponse: Decodable { let blobURI: String }
    return try WuhuJSON.decoder.decode(BlobResponse.self, from: responseData).blobURI
  }

  /// List all registered runners with status.
  public func listRunners() async throws -> [WuhuRunnerInfo] {
    let url = baseURL.appending(path: "v1").appending(path: "runners")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuRunnerInfo].self, from: data)
  }

  // MARK: - Users

  public func listUsers() async throws -> [WuhuUser] {
    let url = baseURL.appending(path: "v1").appending(path: "users")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuUser].self, from: data)
  }

  public func createUser(username: String, kind: WuhuUserKind = .human) async throws -> WuhuUser {
    let url = baseURL.appending(path: "v1").appending(path: "users")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuCreateUserRequest(username: username, kind: kind)), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuUser.self, from: data)
  }

  public func getUser(id: String) async throws -> WuhuUser {
    let url = baseURL.appending(path: "v1").appending(path: "users").appending(path: id)
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuUser.self, from: data)
  }

  public func deleteUser(id: String) async throws {
    let url = baseURL.appending(path: "v1").appending(path: "users").appending(path: id)
    let req = Request(url: url, method: "DELETE")
    _ = try await responseData(for: req)
  }

  // MARK: - Channels

  public func listChannels() async throws -> [WuhuChannel] {
    let url = baseURL.appending(path: "v1").appending(path: "channels")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuChannel].self, from: data)
  }

  public func createChannel(name: String, topic: String? = nil, kind: WuhuChannelKind = .channel) async throws -> WuhuChannel {
    let url = baseURL.appending(path: "v1").appending(path: "channels")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuCreateChannelRequest(name: name, topic: topic, kind: kind)), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuChannel.self, from: data)
  }

  public func getChannel(id: String) async throws -> WuhuChannel {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: id)
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuChannel.self, from: data)
  }

  public func updateChannel(id: String, name: String? = nil, topic: String? = nil) async throws -> WuhuChannel {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: id)
    var req = Request(url: url, method: "PATCH")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuUpdateChannelRequest(name: name, topic: topic)), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuChannel.self, from: data)
  }

  public func deleteChannel(id: String) async throws {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: id)
    let req = Request(url: url, method: "DELETE")
    _ = try await responseData(for: req)
  }

  // MARK: - Channel Members

  public func listChannelMembers(channelID: String) async throws -> [WuhuChannelMember] {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: channelID).appending(path: "members")
    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuChannelMember].self, from: data)
  }

  public func addChannelMember(channelID: String, userID: String, role: WuhuChannelMemberRole = .member) async throws -> WuhuChannelMember {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: channelID).appending(path: "members")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    req.setBody(try WuhuJSON.encoder.encode(WuhuAddChannelMemberRequest(userID: userID, role: role)), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuChannelMember.self, from: data)
  }

  public func removeChannelMember(channelID: String, userID: String) async throws {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: channelID).appending(path: "members").appending(path: userID)
    let req = Request(url: url, method: "DELETE")
    _ = try await responseData(for: req)
  }

  // MARK: - Channel Messages

  public func listChannelMessages(channelID: String, before: Int64? = nil, limit: Int? = nil) async throws -> [WuhuChannelMessage] {
    var url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: channelID).appending(path: "messages")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [URLQueryItem] = []
    if let before { items.append(.init(name: "before", value: String(before))) }
    if let limit { items.append(.init(name: "limit", value: String(limit))) }
    components?.queryItems = items.isEmpty ? nil : items
    url = components?.url ?? url

    let req = Request(url: url, method: "GET")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode([WuhuChannelMessage].self, from: data)
  }

  public func postChannelMessage(channelID: String, content: String, threadID: Int64? = nil, username: String? = nil) async throws -> WuhuChannelMessage {
    let url = baseURL.appending(path: "v1").appending(path: "channels").appending(path: channelID).appending(path: "messages")
    var req = Request(url: url, method: "POST")
    req.setHeader("application/json", for: "Content-Type")
    req.setHeader("application/json", for: "Accept")
    if let username {
      req.setHeader(username, for: "X-Wuhu-User")
    }
    req.setBody(try WuhuJSON.encoder.encode(WuhuPostMessageRequest(content: content, threadID: threadID)), contentType: "application/json")
    let data = try await responseData(for: req)
    return try WuhuJSON.decoder.decode(WuhuChannelMessage.self, from: data)
  }

  private func responseData(for request: Request) async throws -> Data {
    let response = try await fetch(request)
    try response.validateStatus()
    return try await response.data()
  }
}
