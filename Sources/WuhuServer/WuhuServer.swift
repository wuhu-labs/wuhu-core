import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdWebSocket
import Logging
import Mux
import MuxSocket
import NIOCore
import WuhuAPI
import WuhuCore

public struct WuhuServer: Sendable {
  public init() {}

  public func run(configPath: String?, llmRequestLogDir: String? = nil) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuServerConfig.defaultPath()
    let config = try WuhuServerConfig.load(path: path)

    if let openai = config.llm?.openai, !openai.isEmpty {
      setenv("OPENAI_API_KEY", openai, 1)
    }
    if let anthropic = config.llm?.anthropic, !anthropic.isEmpty {
      setenv("ANTHROPIC_API_KEY", anthropic, 1)
    }

    let dbPath: String = {
      if let p = config.databasePath, !p.isEmpty { return (p as NSString).expandingTildeInPath }
      let home = FileManager.default.homeDirectoryForCurrentUser
      return home.appendingPathComponent(".wuhu/wuhu.sqlite").path
    }()
    try ensureDirectoryExists(forDatabasePath: dbPath)

    let store = try SQLiteSessionStore(path: dbPath)

    let blobRoot: String = {
      let dbDir = URL(fileURLWithPath: dbPath, isDirectory: false).deletingLastPathComponent()
      return dbDir.appendingPathComponent("blobs", isDirectory: true).path
    }()
    let blobStore = WuhuBlobStore(rootDirectory: blobRoot)

    let workspaceRoot = config.resolveWorkspaceRoot(databasePath: dbPath)

    let workspaceDocsStore = try WuhuWorkspaceDocsStore(
      workspaceRoot: URL(fileURLWithPath: workspaceRoot, isDirectory: true),
    )
    try workspaceDocsStore.ensureDefaultDirectories()
    workspaceDocsStore.startWatching()

    let effectiveLogDir: String? = {
      if let llmRequestLogDir, !llmRequestLogDir.isEmpty { return llmRequestLogDir }
      if let fromConfig = config.llmRequestLogDir, !fromConfig.isEmpty { return fromConfig }
      return nil
    }()

    let requestLogger: WuhuLLMRequestLogger? = effectiveLogDir.flatMap { raw in
      let expanded = (raw as NSString).expandingTildeInPath
      return try? WuhuLLMRequestLogger(directoryURL: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    // Runner registry — connect to configured remote runners
    let runnerRegistry = RunnerRegistry()
    let logger = Logger(label: "WuhuServer")

    // Declare configured runner names so they always appear in list_runners
    if let runners = config.runners, !runners.isEmpty {
      await runnerRegistry.declareConfigured(runners.map(\.name))
    }

    // Runner tasks are retained to keep the connections alive for the server lifetime.
    // They auto-cancel when the process exits.
    var _runnerTasks: [Task<Void, Never>] = []
    if let runners = config.runners, !runners.isEmpty {
      let muxRunners = runners.map { r -> (name: String, host: String, port: Int) in
        let (h, p) = Self.parseHostPort(r.address, defaultPort: 5532)
        return (name: r.name, host: h, port: p)
      }
      _runnerTasks = WuhuMuxRunnerConnector.connectAll(
        runners: muxRunners,
        registry: runnerRegistry,
        logger: logger,
      )
    }

    // Spawn local runner as a child process over UDS
    let localRunnerSpawner = WuhuLocalRunnerSpawner(
      socketPath: config.localRunnerSocket,
      registry: runnerRegistry,
      logger: logger,
    )
    try await localRunnerSpawner.start()

    // Start runner connection tasks for configured outbound runners
    let port = config.port ?? 5530
    let host = (config.host?.isEmpty == false) ? config.host! : "127.0.0.1"

    let service = WuhuService(
      store: store,
      blobStore: blobStore,
      llmRequestLogger: requestLogger,
      workspaceRoot: workspaceRoot,
      braveSearchAPIKey: config.braveSearchAPIKey,
      runnerRegistry: runnerRegistry,
    )
    await service.startAgentLoopManager()

    let router = Router(context: WuhuRequestContext.self)

    @Sendable func resolveMountTemplate(_ identifier: String, missingStatus: HTTPResponse.Status) async throws -> WuhuMountTemplate {
      do {
        return try await store.getMountTemplate(identifier: identifier)
      } catch let err as WuhuMountTemplateResolutionError {
        switch err {
        case .unknownMountTemplate:
          throw HTTPError(missingStatus, message: err.description)
        case .unsupportedType:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
    }

    router.get("healthz") { _, _ -> String in
      "ok"
    }

    // MARK: - Mount Templates (replacing environments)

    router.get("v1/mount-templates") { request, context async throws -> Response in
      let templates = try await store.listMountTemplates()
      return try context.responseEncoder.encode(templates, from: request, context: context)
    }

    router.post("v1/mount-templates") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateMountTemplateRequest.self, context: context)
      let name = create.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let templatePath = create.templatePath.trimmingCharacters(in: .whitespacesAndNewlines)
      let workspacesPath = create.workspacesPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw HTTPError(.badRequest, message: "Mount template name is required") }
      guard !templatePath.isEmpty else { throw HTTPError(.badRequest, message: "templatePath is required") }
      guard !workspacesPath.isEmpty else { throw HTTPError(.badRequest, message: "workspacesPath is required") }

      let mt = try await store.createMountTemplate(create)
      return try context.responseEncoder.encode(mt, from: request, context: context)
    }

    router.get("v1/mount-templates/:identifier") { request, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      let mt = try await resolveMountTemplate(identifier, missingStatus: .notFound)
      return try context.responseEncoder.encode(mt, from: request, context: context)
    }

    router.patch("v1/mount-templates/:identifier") { request, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      let update = try await request.decode(as: WuhuUpdateMountTemplateRequest.self, context: context)
      _ = try await resolveMountTemplate(identifier, missingStatus: .notFound)
      let mt = try await store.updateMountTemplate(identifier: identifier, request: update)
      return try context.responseEncoder.encode(mt, from: request, context: context)
    }

    router.delete("v1/mount-templates/:identifier") { _, context async throws -> Response in
      let identifier = try context.parameters.require("identifier")
      do {
        try await store.deleteMountTemplate(identifier: identifier)
      } catch let err as WuhuMountTemplateResolutionError {
        switch err {
        case .unknownMountTemplate:
          throw HTTPError(.notFound, message: err.description)
        case .unsupportedType:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
      return Response(status: .noContent)
    }

    // MARK: - Workspace docs

    router.get("v1/workspace/docs") { _, _ async throws -> [WuhuWorkspaceDocSummary] in
      try await workspaceDocsStore.listDocs()
    }

    router.get("v1/workspace/doc") { request, context async throws -> Response in
      struct Query: Decodable { var path: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      do {
        let doc = try await workspaceDocsStore.readDoc(relativePath: query.path)
        return try context.responseEncoder.encode(doc, from: request, context: context)
      } catch let err as WuhuWorkspaceDocsStoreError {
        switch err {
        case .notFound:
          throw HTTPError(.notFound, message: err.description)
        default:
          throw HTTPError(.badRequest, message: err.description)
        }
      }
    }

    // MARK: - Blob endpoints

    router.post("v1/sessions/:id/blobs") { request, context async throws -> Response in
      let sessionID = try context.parameters.require("id")
      let contentType = request.headers[.contentType] ?? "application/octet-stream"
      let mimeType = String(contentType)

      var body = try await request.body.collect(upTo: WuhuBlobStore.maxImageFileSize + 1024)
      let data = if let bytes = body.readBytes(length: body.readableBytes) {
        Data(bytes)
      } else {
        Data()
      }

      guard data.count <= WuhuBlobStore.maxImageFileSize else {
        throw HTTPError(.badRequest, message: "Image too large. Max: \(WuhuBlobStore.maxImageFileSize / 1024 / 1024)MB")
      }

      let uri = try blobStore.store(sessionID: sessionID, data: data, mimeType: mimeType)

      struct BlobUploadResponse: Encodable {
        let blobURI: String
        let mimeType: String
      }

      return try context.responseEncoder.encode(
        BlobUploadResponse(blobURI: uri, mimeType: mimeType),
        from: request,
        context: context,
      )
    }

    router.get("v1/sessions/:id/blobs/:filename") { _, context async throws -> Response in
      let sessionID = try context.parameters.require("id")
      let filename = try context.parameters.require("filename")
      let uri = "blob://\(sessionID)/\(filename)"

      let data: Data
      do {
        data = try blobStore.resolve(uri: uri)
      } catch {
        throw HTTPError(.notFound, message: "Blob not found: \(filename)")
      }

      let ext = filename.split(separator: ".").last.map(String.init) ?? ""
      let mimeType = WuhuBlobStore.mimeTypeForExtension(ext) ?? "application/octet-stream"

      var buffer = ByteBuffer()
      buffer.writeBytes(data)

      return Response(
        status: .ok,
        headers: [.contentType: mimeType],
        body: .init(byteBuffer: buffer),
      )
    }

    // MARK: - Sessions

    router.get("v1/sessions") { request, context async throws -> [WuhuSession] in
      struct Query: Decodable {
        var limit: Int?
        var includeArchived: Bool?
      }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      return try await service.listSessions(limit: query.limit, includeArchived: query.includeArchived ?? false)
    }

    router.get("v1/sessions/:id") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable {
        var sinceCursor: Int64?
        var sinceTime: Double?
      }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      let sinceTime = query.sinceTime.map { Date(timeIntervalSince1970: $0) }
      let session = try await service.getSession(id: id)
      let transcript: [WuhuSessionEntry] = if query.sinceCursor != nil || sinceTime != nil {
        try await service.getTranscript(sessionID: id, sinceCursor: query.sinceCursor, sinceTime: sinceTime)
      } else {
        try await service.getTranscript(sessionID: id)
      }
      let inProcessExecution = await service.inProcessExecutionInfo(sessionID: id)
      let response = WuhuGetSessionResponse(session: session, transcript: transcript, inProcessExecution: inProcessExecution)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions") { request, context async throws -> Response in
      let create = try await request.decode(as: WuhuCreateSessionRequest.self, context: context)

      let model = (create.model?.isEmpty == false) ? create.model! : WuhuModelCatalog.defaultModelID(for: create.provider)
      let systemPrompt: String = if let prompt = create.systemPrompt, !prompt.isEmpty {
        prompt
      } else {
        WuhuDefaultSystemPrompts.codingAgent
      }
      let sessionID = UUID().uuidString.lowercased()

      let cwd: String?
      var mountToEmit: WuhuMount?

      if let mountPath = create.mountPath, !mountPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Direct path mount
        let resolvedPath = ToolPath.resolveToCwd(mountPath, cwd: FileManager.default.currentDirectoryPath)
        cwd = resolvedPath
      } else if let mtIdentifier = create.mountTemplate, !mtIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // Mount template
        let mt = try await resolveMountTemplate(mtIdentifier, missingStatus: .badRequest)
        let serverCwd = FileManager.default.currentDirectoryPath
        let templatePath = ToolPath.resolveToCwd(mt.templatePath, cwd: serverCwd)
        let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(mt.workspacesPath)
        let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
          sessionID: sessionID,
          templatePath: templatePath,
          startupScript: mt.startupScript,
          workspacesPath: workspacesRoot,
        )
        cwd = workspacePath
      } else {
        // No mount
        cwd = nil
      }

      _ = try await service.createSession(
        sessionID: sessionID,
        provider: create.provider,
        model: model,
        reasoningEffort: create.reasoningEffort,
        systemPrompt: systemPrompt,
        cwd: cwd,
        parentSessionID: create.parentSessionID,
      )

      // Create mount record if we have a cwd
      if let cwd {
        let mountName: String
        let mountTemplateID: String?

        if let mtIdentifier = create.mountTemplate, !mtIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let mt = try await store.getMountTemplate(identifier: mtIdentifier)
          mountName = mt.name
          mountTemplateID = mt.id
        } else {
          let candidate = URL(fileURLWithPath: cwd).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
          mountName = candidate.isEmpty ? "workspace" : candidate
          mountTemplateID = nil
        }

        let mount = try await store.createMount(
          sessionID: sessionID,
          name: mountName,
          path: cwd,
          mountTemplateID: mountTemplateID,
          isPrimary: true,
        )
        mountToEmit = mount
      }

      // Emit mount-level context entries
      if let mount = mountToEmit {
        try await service.emitMountContext(sessionID: sessionID, mount: mount)
      }

      let finalSession = try await service.getSession(id: sessionID)
      return try context.responseEncoder.encode(finalSession, from: request, context: context)
    }

    router.get("v1/sessions/:id/mounts") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let mounts = try await store.listMounts(sessionID: id)
      return try context.responseEncoder.encode(mounts, from: request, context: context)
    }

    router.patch("v1/sessions/:id") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let rename = try await request.decode(as: WuhuRenameSessionRequest.self, context: context)
      let session = try await service.renameSession(sessionID: id, title: rename.title)
      let response = WuhuRenameSessionResponse(session: session)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/model") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let setModel = try await request.decode(as: WuhuSetSessionModelRequest.self, context: context)
      let response = try await service.setSessionModel(sessionID: id, request: setModel)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/stop") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let stopRequest = await (try? request.decode(as: WuhuStopSessionRequest.self, context: context)) ?? WuhuStopSessionRequest()
      let response = try await service.stopSession(sessionID: id, user: stopRequest.user)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/archive") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let session = try await service.archiveSession(sessionID: id)
      let response = WuhuArchiveSessionResponse(session: session)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.post("v1/sessions/:id/unarchive") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      let session = try await service.unarchiveSession(sessionID: id)
      let response = WuhuArchiveSessionResponse(session: session)
      return try context.responseEncoder.encode(response, from: request, context: context)
    }

    router.get("v1/sessions/:id/follow") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable {
        var sinceCursor: Int64?
        var sinceTime: Double?
        var stopAfterIdle: Int?
        var timeoutSeconds: Double?
      }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      let sinceTime = query.sinceTime.map { Date(timeIntervalSince1970: $0) }
      let stopAfterIdle = (query.stopAfterIdle ?? 0) != 0

      let stream = try await service.followSessionStream(
        sessionID: id,
        sinceCursor: query.sinceCursor,
        sinceTime: sinceTime,
        stopAfterIdle: stopAfterIdle,
        timeoutSeconds: query.timeoutSeconds,
      )

      let byteStream = AsyncStream<ByteBuffer> { continuation in
        let task = Task {
          func yieldEvent(_ apiEvent: WuhuSessionStreamEvent) {
            let data = try! WuhuJSON.encoder.encode(apiEvent)
            var s = "data: "
            s += String(decoding: data, as: UTF8.self)
            s += "\n\n"
            continuation.yield(ByteBuffer(string: s))
          }

          do {
            for try await event in stream {
              yieldEvent(event)
              if case .done = event { break }
            }
          } catch {
            yieldEvent(.assistantTextDelta("\n[error] \(error)\n"))
            yieldEvent(.done)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }

      var headers = HTTPFields()
      headers[.contentType] = "text/event-stream"
      headers[.cacheControl] = "no-cache"
      headers[.connection] = "keep-alive"

      return Response(
        status: .ok,
        headers: headers,
        body: ResponseBody(asyncSequence: byteStream),
      )
    }

    // MARK: - Session contracts (commands + subscription)

    router.post("v1/sessions/:id/enqueue") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable { var lane: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      guard let lane = UserQueueLane(rawValue: query.lane) else {
        throw HTTPError(.badRequest, message: "Invalid lane: \(query.lane)")
      }

      let message = try await request.decode(as: QueuedUserMessage.self, context: context)
      let qid = try await service.enqueue(sessionID: .init(rawValue: id), message: message, lane: lane)
      return try context.responseEncoder.encode(qid, from: request, context: context)
    }

    router.post("v1/sessions/:id/cancel") { request, context async throws -> Response in
      let id = try context.parameters.require("id")
      struct Query: Decodable { var lane: String }
      let query = try request.uri.decodeQuery(as: Query.self, context: context)
      guard let lane = UserQueueLane(rawValue: query.lane) else {
        throw HTTPError(.badRequest, message: "Invalid lane: \(query.lane)")
      }

      struct Body: Decodable { var id: QueueItemID }
      let body = try await request.decode(as: Body.self, context: context)
      try await service.cancel(sessionID: .init(rawValue: id), id: body.id, lane: lane)

      return Response(status: .ok)
    }

    router.get("v1/sessions/:id/subscribe") { request, context async throws -> Response in
      let id = try context.parameters.require("id")

      struct Query: Decodable {
        var transcriptSince: String?
        var transcriptPageSize: Int?
        var systemSince: String?
        var steerSince: String?
        var followUpSince: String?
      }

      let query = try request.uri.decodeQuery(as: Query.self, context: context)

      let subRequest = SessionSubscriptionRequest(
        transcriptSince: query.transcriptSince.flatMap { $0.isEmpty ? nil : TranscriptCursor(rawValue: $0) },
        transcriptPageSize: query.transcriptPageSize ?? 200,
        systemSince: query.systemSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
        steerSince: query.steerSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
        followUpSince: query.followUpSince.flatMap { $0.isEmpty ? nil : QueueCursor(rawValue: $0) },
      )

      let subscription = try await service.subscribe(sessionID: .init(rawValue: id), since: subRequest)

      let byteStream = AsyncStream<ByteBuffer> { continuation in
        let task = Task {
          func yieldFrame(_ frame: SessionSubscriptionSSEFrame) -> Bool {
            guard let data = try? WuhuJSON.encoder.encode(frame) else { return false }
            var s = "data: "
            s += String(decoding: data, as: UTF8.self)
            s += "\n\n"
            continuation.yield(ByteBuffer(string: s))
            return true
          }

          guard yieldFrame(.initial(subscription.initial)) else {
            continuation.finish()
            return
          }

          do {
            for try await event in subscription.events {
              if !yieldFrame(.event(event)) {
                break
              }
            }
          } catch {
            // Best-effort: close stream. Clients retry.
          }

          continuation.finish()
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }

      var headers = HTTPFields()
      headers[.contentType] = "text/event-stream"
      headers[.cacheControl] = "no-cache"
      headers[.connection] = "keep-alive"

      return Response(
        status: .ok,
        headers: headers,
        body: ResponseBody(asyncSequence: byteStream),
      )
    }

    // MARK: - Runners

    router.get("v1/runners") { _, _ async throws -> [WuhuRunnerInfo] in
      let runners = await runnerRegistry.listAll()
      return runners.map { WuhuRunnerInfo(name: $0.name, source: $0.source.rawValue, isConnected: $0.isConnected) }
    }

    // WebSocket router for incoming runner connections
    let wsRouter = WuhuMuxRunnerAcceptor.webSocketRouter(
      registry: runnerRegistry,
      logger: logger,
    )

    // Configure WebSocket with larger max frame size (1MB) to handle large RPC payloads.
    // TODO: Fix wuhu-yamux WebSocketConnection to chunk writes instead of requiring this.
    let wsConfig = WebSocketServerConfiguration(maxFrameSize: 1 << 20)

    let app = Application(
      router: router,
      server: .http1WebSocketUpgrade(webSocketRouter: wsRouter, configuration: wsConfig),
      configuration: .init(address: .hostname(host, port: port)),
      logger: logger,
    )
    try await app.runService()

    // Shutdown: stop local runner and cancel remote runner connections
    await localRunnerSpawner.stop()
    for task in _runnerTasks {
      task.cancel()
    }
  }

  /// Parse "host:port" from a runner address string.
  static func parseHostPort(_ address: String, defaultPort: Int) -> (String, Int) {
    // Strip protocol prefixes if present
    var addr = address
    for prefix in ["ws://", "wss://", "http://", "https://"] {
      if addr.hasPrefix(prefix) {
        addr = String(addr.dropFirst(prefix.count))
        break
      }
    }
    // Strip path
    if let slashIdx = addr.firstIndex(of: "/") {
      addr = String(addr[addr.startIndex ..< slashIdx])
    }
    // Split host:port
    if let colonIdx = addr.lastIndex(of: ":"),
       let port = Int(addr[addr.index(after: colonIdx)...])
    {
      return (String(addr[addr.startIndex ..< colonIdx]), port)
    }
    return (addr, defaultPort)
  }
}

private func ensureDirectoryExists(forDatabasePath path: String) throws {
  guard path != ":memory:" else { return }
  let url = URL(fileURLWithPath: path)
  let dir = url.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}
