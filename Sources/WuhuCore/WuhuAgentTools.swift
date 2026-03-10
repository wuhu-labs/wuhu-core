import Foundation
import Logging
import PiAI
import WuhuAPI

private let logger = WuhuDebugLogger.logger("WuhuAgentTools")

enum WuhuAgentToolNames {
  static let bash = "bash"
  static let asyncBash = "async_bash"
  static let asyncBashStatus = "async_bash_status"

  static let listChildSessions = "list_child_sessions"
  static let readSessionFinalMessage = "read_session_final_message"
  static let sessionSteer = "session_steer"
  static let sessionFollowUp = "session_follow_up"
  static let mountTemplateList = "mount_template_list"
  static let mountTemplateGet = "mount_template_get"
  static let createSession = "create_session"
  static let joinSessions = "join_sessions"
  static let mount = "mount"
  static let listRunners = "list_runners"
}

extension WuhuService {
  func agentToolset(
    session: WuhuSession,
    baseTools: [AnyAgentTool],
  ) -> [AnyAgentTool] {
    var tools = baseTools
    tools.append(contentsOf: agentManagementTools(currentSessionID: session.id))
    return tools
  }

  private func agentManagementTools(currentSessionID: String) -> [AnyAgentTool] {
    [
      createSessionTool(currentSessionID: currentSessionID),
      listChildSessionsTool(currentSessionID: currentSessionID),
      readSessionFinalMessageTool(currentSessionID: currentSessionID),
      joinSessionsTool(currentSessionID: currentSessionID),
      sessionSteerTool(),
      sessionFollowUpTool(),
      mountTemplateListTool(),
      mountTemplateGetTool(),
      mountTool(currentSessionID: currentSessionID),
      listRunnersTool(),
    ]
  }

  private func createSessionTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var task: String
      var mountTemplateID: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let task = try a.requireString("task")
        let mountTemplateID = try a.requireString("mountTemplateID")
        try a.ensureNoExtraKeys(allowed: ["task", "mountTemplateID"])
        return .init(task: task, mountTemplateID: mountTemplateID)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "task": .object([
          "type": .string("string"),
          "description": .string("Task description for the new coding session"),
        ]),
        "mountTemplateID": .object([
          "type": .string("string"),
          "description": .string("Mount template UUID or unique name to instantiate for the new session"),
        ]),
      ]),
      "required": .array([.string("task"), .string("mountTemplateID")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.createSession,
      description: "Create a fresh coding session from a mount template with no conversation history. Instantiates a new workspace from the template. Use this for subagent-style dispatch where history inheritance is unwanted.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.createSession) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let task = params.task.trimmingCharacters(in: .whitespacesAndNewlines)
      let mountTemplateID = params.mountTemplateID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !task.isEmpty else { throw WuhuToolExecutionError(message: "task must not be empty") }
      guard !mountTemplateID.isEmpty else { throw WuhuToolExecutionError(message: "mountTemplateID must not be empty") }

      let child = try await createDirectSession(
        parentSessionID: currentSessionID,
        mountTemplateIdentifier: mountTemplateID,
        task: task,
      )

      return try AgentToolResult(
        content: [.text("Created coding session: session://\(child.id)")],
        details: .object([
          "sessionID": .string(child.id),
          "session": WuhuJSON.encoder.encodeToJSONValue(child),
        ]),
      )
    }
  }

  private func listChildSessionsTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        try a.ensureNoExtraKeys(allowed: [])
        return .init()
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.listChildSessions,
      description: "List child sessions created by this session (by parentSessionID), including status and unread final-message state.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.listChildSessions) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      _ = try Params.parse(toolName: tool.name, args: args)

      let children = try await store.listChildSessions(parentSessionID: currentSessionID)

      let lines = children.map { record in
        "\(record.session.id) [\(record.executionStatus.rawValue)]"
      }

      let sessionsJSON: [JSONValue] = children.map { record in
        .object([
          "id": .string(record.session.id),
          "status": .string(record.executionStatus.rawValue),
        ])
      }

      return AgentToolResult(
        content: [.text(lines.isEmpty ? "(no child sessions)" : lines.joined(separator: "\n"))],
        details: .object(["sessions": .array(sessionsJSON)]),
      )
    }
  }

  private func readSessionFinalMessageTool(currentSessionID _: String) -> AnyAgentTool {
    struct Params: Sendable {
      var sessionID: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let sessionID = try a.requireString("sessionID")
        try a.ensureNoExtraKeys(allowed: ["sessionID"])
        return .init(sessionID: sessionID)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "sessionID": .object([
          "type": .string("string"),
          "description": .string("Child session id (or any session id)"),
        ]),
      ]),
      "required": .array([.string("sessionID")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.readSessionFinalMessage,
      description: "Read the final assistant message for a session (the last assistant message without tool calls). If this session is the parent, marks it as read.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.readSessionFinalMessage) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let targetID = params.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !targetID.isEmpty else { throw WuhuToolExecutionError(message: "sessionID is required") }

      let final = try await loadFinalAssistantMessage(sessionID: targetID)

      return AgentToolResult(
        content: [.text(final.text)],
        details: .object([
          "sessionID": .string(targetID),
          "entryID": .string(String(final.entryID)),
        ]),
      )
    }
  }

  private func joinSessionsTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var sessionIDs: [String]
      var timeout: Double?

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let sessionIDs = try a.requireStringArray("sessionIDs")
        let timeout = try a.optionalDouble("timeout")
        try a.ensureNoExtraKeys(allowed: ["sessionIDs", "timeout"])
        return .init(sessionIDs: sessionIDs, timeout: timeout)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "sessionIDs": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
          "description": .string("Session IDs to wait for. All must be child sessions of the current session."),
        ]),
        "timeout": .object([
          "type": .string("number"),
          "description": .string("Maximum seconds to wait before returning with partial results (optional, default: 3600)."),
        ]),
      ]),
      "required": .array([.string("sessionIDs")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.joinSessions,
      description: "Wait for one or more child sessions to finish (reach idle or stopped state). Blocks until all specified sessions are no longer running, then returns their final statuses and messages. Use this after dispatching parallel sessions with create_session or fork.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.joinSessions) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)

      let ids = params.sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !ids.isEmpty else { throw WuhuToolExecutionError(message: "sessionIDs must not be empty") }

      let children = try await store.listChildSessions(parentSessionID: currentSessionID)
      let childIDs = Set(children.map(\.session.id))
      for id in ids {
        guard childIDs.contains(id) else {
          throw WuhuToolExecutionError(message: "Session '\(id)' is not a child of the current session")
        }
      }

      let timeout = params.timeout ?? 3600
      let deadline = Date().addingTimeInterval(timeout)
      var pending = Set(ids)

      struct SessionResult: Sendable {
        var id: String
        var status: String
        var finalMessage: String?
        var finalEntryID: Int64?
      }
      var results: [SessionResult] = []

      do {
        let snapshot = try await store.listChildSessions(parentSessionID: currentSessionID)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.session.id, $0) })

        for id in pending {
          guard let record = byID[id] else { continue }
          if record.executionStatus != .running {
            let final = try? await loadFinalAssistantMessage(sessionID: id)
            results.append(.init(id: id, status: record.executionStatus.rawValue, finalMessage: final?.text, finalEntryID: final?.entryID))
          }
        }
        for r in results {
          pending.remove(r.id)
        }
      }

      var intervalNs: UInt64 = 2_000_000_000
      let maxIntervalNs: UInt64 = 30_000_000_000

      while !pending.isEmpty, Date() < deadline {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: intervalNs)
        intervalNs = min(intervalNs * 2, maxIntervalNs)

        let snapshot = try await store.listChildSessions(parentSessionID: currentSessionID)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.session.id, $0) })

        var newlyDone: [String] = []
        for id in pending {
          guard let record = byID[id] else { continue }
          if record.executionStatus != .running {
            let final = try? await loadFinalAssistantMessage(sessionID: id)
            results.append(.init(id: id, status: record.executionStatus.rawValue, finalMessage: final?.text, finalEntryID: final?.entryID))
            newlyDone.append(id)
          }
        }
        for id in newlyDone {
          pending.remove(id)
        }
      }

      let allDone = pending.isEmpty

      let completedJSON: [JSONValue] = results.map { r in
        .object([
          "sessionID": .string(r.id),
          "status": .string(r.status),
          "finalMessage": r.finalMessage.map { .string($0) } ?? .null,
          "finalEntryID": r.finalEntryID.map { .number(Double($0)) } ?? .null,
        ])
      }
      let timedOutJSON: [JSONValue] = pending.sorted().map { id in
        .object([
          "sessionID": .string(id),
          "status": .string("running"),
        ])
      }

      let summary = results.map { "✅ \($0.id) [\($0.status)]" }
        + pending.sorted().map { "⏳ \($0) [still running]" }

      var text = allDone
        ? "All \(ids.count) session\(ids.count == 1 ? "" : "s") completed."
        : "\(results.count)/\(ids.count) completed, \(pending.count) timed out."
      text += "\n\n" + summary.joined(separator: "\n")

      if !allDone {
        text += "\n\nUse join_sessions again with the timed-out IDs to continue waiting."
      }

      for r in results {
        guard let msg = r.finalMessage else { continue }
        text += "\n\n--- \(r.id) ---\n\(msg)"
      }

      return AgentToolResult(
        content: [.text(text)],
        details: .object([
          "completed": .bool(allDone),
          "sessions": .array(completedJSON),
          "timedOut": .array(timedOutJSON),
        ]),
      )
    }
  }

  private func sessionSteerTool() -> AnyAgentTool {
    sessionEnqueueTool(name: WuhuAgentToolNames.sessionSteer, lane: .steer)
  }

  private func sessionFollowUpTool() -> AnyAgentTool {
    sessionEnqueueTool(name: WuhuAgentToolNames.sessionFollowUp, lane: .followUp)
  }

  private func sessionEnqueueTool(name: String, lane: UserQueueLane) -> AnyAgentTool {
    struct Params: Sendable {
      var sessionID: String
      var message: String

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let sessionID = try a.requireString("sessionID")
        let message = try a.requireString("message")
        try a.ensureNoExtraKeys(allowed: ["sessionID", "message"])
        return .init(sessionID: sessionID, message: message)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "sessionID": .object(["type": .string("string"), "description": .string("Target session id")]),
        "message": .object(["type": .string("string"), "description": .string("Message text to inject")]),
      ]),
      "required": .array([.string("sessionID"), .string("message")]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: name,
      description: "Inject a message into a session via the \(lane.rawValue) lane.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: name) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let targetID = params.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = params.message.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !targetID.isEmpty else { throw WuhuToolExecutionError(message: "sessionID is required") }
      guard !text.isEmpty else { throw WuhuToolExecutionError(message: "message is required") }

      let author: Author = .participant(.init(rawValue: "channel-agent"), kind: .bot)
      let message = QueuedUserMessage(author: author, content: .text(text))
      let qid = try await enqueue(sessionID: .init(rawValue: targetID), message: message, lane: lane)

      return AgentToolResult(
        content: [.text("enqueued \(lane.rawValue) id=\(qid.rawValue)")],
        details: .object(["queueID": .string(qid.rawValue)]),
      )
    }
  }

  private func mountTemplateListTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: WuhuAgentToolNames.mountTemplateList, description: "List available mount templates.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.mountTemplateList) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      try a.ensureNoExtraKeys(allowed: [])

      let templates = try await store.listMountTemplates()
      let lines = templates.map { "\($0.name) (\($0.type.rawValue)) id=\($0.id)" }
      let json: [JSONValue] = templates.map { t in
        (try? WuhuJSON.encoder.encodeToJSONValue(t)) ?? .null
      }
      return AgentToolResult(
        content: [.text(lines.isEmpty ? "(no mount templates)" : lines.joined(separator: "\n"))],
        details: .object(["mountTemplates": .array(json)]),
      )
    }
  }

  private func mountTemplateGetTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "identifier": .object(["type": .string("string"), "description": .string("Mount template UUID or unique name")]),
      ]),
      "required": .array([.string("identifier")]),
      "additionalProperties": .bool(false),
    ])
    let tool = Tool(name: WuhuAgentToolNames.mountTemplateGet, description: "Get a mount template definition.", parameters: schema)

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.mountTemplateGet) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let a = try ToolArgs(toolName: tool.name, args: args)
      let identifier = try a.requireString("identifier").trimmingCharacters(in: .whitespacesAndNewlines)
      try a.ensureNoExtraKeys(allowed: ["identifier"])
      guard !identifier.isEmpty else { throw WuhuToolExecutionError(message: "identifier is required") }

      let t = try await store.getMountTemplate(identifier: identifier)
      return try AgentToolResult(
        content: [.text("\(t.name) (\(t.type.rawValue)) id=\(t.id)\ntemplatePath=\(t.templatePath)")],
        details: WuhuJSON.encoder.encodeToJSONValue(t),
      )
    }
  }

  private func mountTool(currentSessionID: String) -> AnyAgentTool {
    struct Params: Sendable {
      var path: String?
      var name: String?
      var mountTemplateID: String?
      var primary: Bool?
      var runner: String?

      static func parse(toolName: String, args: JSONValue) throws -> Params {
        let a = try ToolArgs(toolName: toolName, args: args)
        let path = try a.optionalString("path")
        let name = try a.optionalString("name")
        let mountTemplateID = try a.optionalString("mountTemplateID")
        let primary = try a.optionalBool("primary")
        let runner = try a.optionalString("runner")
        try a.ensureNoExtraKeys(allowed: ["path", "name", "mountTemplateID", "primary", "runner"])
        return .init(path: path, name: name, mountTemplateID: mountTemplateID, primary: primary, runner: runner)
      }
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "path": .object(["type": .string("string"), "description": .string("Absolute path to the directory to mount. If omitted or empty, creates a scratch directory for this session.")]),
        "name": .object(["type": .string("string"), "description": .string("Optional label for the mount")]),
        "mountTemplateID": .object(["type": .string("string"), "description": .string("Mount template UUID or unique name. If provided, instantiates a fresh workspace from the template and mounts it. Mutually exclusive with path.")]),
        "primary": .object(["type": .string("boolean"), "description": .string("Whether this mount is the primary mount (determines cwd). If omitted, the first mount becomes primary.")]),
        "runner": .object(["type": .string("string"), "description": .string("Runner name for this mount. Omit for local execution. Use a configured runner name for remote execution.")]),
      ]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.mount,
      description: "Mount a directory as the working directory for this session. Changes the cwd for all filesystem and bash tools. Injects AGENTS.md and skills from the mounted directory. Can be called multiple times to switch directories. Call with no path (or empty path) to create a scratch directory. Pass mountTemplateID to instantiate a fresh workspace from a mount template.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.mount) { [weak self] _, args in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }
      let params = try Params.parse(toolName: tool.name, args: args)
      let rawPath = (params.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let rawTemplateID = (params.mountTemplateID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let rawRunner = (params.runner ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

      logger.debug(
        "mount tool called",
        metadata: [
          "sessionID": "\(currentSessionID)",
          "path": "\(rawPath.isEmpty ? "(empty)" : rawPath)",
          "name": "\(params.name ?? "(none)")",
          "templateID": "\(rawTemplateID.isEmpty ? "(none)" : rawTemplateID)",
          "runner": "\(rawRunner.isEmpty ? "(none)" : rawRunner)",
          "primary": "\(params.primary.map { String($0) } ?? "(auto)")",
        ],
      )

      if !rawPath.isEmpty, !rawTemplateID.isEmpty {
        throw WuhuToolExecutionError(message: "path and mountTemplateID are mutually exclusive — provide one or the other")
      }

      // Resolve runner
      let runnerID: RunnerID = if rawRunner.isEmpty || rawRunner == "local" {
        .local
      } else {
        .remote(name: rawRunner)
      }

      // Look up and validate runner
      let runner = await runnerRegistry.get(runnerID)
      guard let runner else {
        throw await WuhuToolExecutionError(message: "Runner '\(runnerID.displayName)' is not connected. Available runners: \(runnerRegistry.listRunnerNames().joined(separator: ", "))")
      }

      let mountPath: String
      var mountTemplateID: String?

      if !rawTemplateID.isEmpty {
        // Instantiate a fresh workspace from the mount template (via runner for remote)
        let resolved = try await materializeMountTemplate(identifier: rawTemplateID, sessionID: currentSessionID, runner: runner)
        mountPath = resolved.workspacePath
        mountTemplateID = resolved.templateID
      } else if rawPath.isEmpty {
        // Create a scratch directory tied to this session ID
        mountPath = try WuhuScratchDirectory.create(sessionID: currentSessionID)
      } else {
        mountPath = rawPath
      }

      // For local mounts, verify directory exists
      if runnerID == .local {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPath, isDirectory: &isDir), isDir.boolValue else {
          throw WuhuToolExecutionError(message: "Directory not found: \(mountPath)")
        }
      }

      let mountName = (params.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let effectiveName: String = if !mountName.isEmpty {
        mountName
      } else if !rawTemplateID.isEmpty {
        rawTemplateID
      } else {
        URL(fileURLWithPath: mountPath).lastPathComponent
      }

      // Determine primary: explicit > first-mount-is-primary
      let existingMounts = try await store.listMounts(sessionID: currentSessionID)
      let isPrimary: Bool = if let explicit = params.primary {
        explicit
      } else {
        existingMounts.isEmpty
      }

      let mount = try await store.createMount(
        sessionID: currentSessionID,
        name: effectiveName,
        path: mountPath,
        mountTemplateID: mountTemplateID,
        isPrimary: isPrimary,
        runnerID: runnerID,
      )

      // Update cwd if this is the primary mount
      if isPrimary {
        try await store.setSessionCwd(sessionID: currentSessionID, cwd: mountPath)
      }

      // Emit context entries (AGENTS.md, skills) — uses runner for remote mounts
      try await emitMountContext(sessionID: currentSessionID, mount: mount, runner: runner)

      logger.debug(
        "mount created",
        metadata: [
          "sessionID": "\(currentSessionID)",
          "mountID": "\(mount.id)",
          "name": "\(effectiveName)",
          "path": "\(mountPath)",
          "isPrimary": "\(mount.isPrimary)",
          "runner": "\(runnerID.wireValue)",
        ],
      )

      return AgentToolResult(
        content: [.text("Mounted '\(effectiveName)' at \(mountPath)\(runnerID == .local ? "" : " (runner: \(runnerID.displayName))")")],
        details: .object([
          "mountID": .string(mount.id),
          "name": .string(effectiveName),
          "path": .string(mountPath),
          "isPrimary": .bool(mount.isPrimary),
          "runner": .string(runnerID.wireValue),
        ]),
      )
    }
  }

  // MARK: - Mount Template Materialization

  private struct MaterializedTemplate: Sendable {
    var templateID: String
    var workspacePath: String
  }

  private func materializeMountTemplate(identifier: String, sessionID: String, runner: (any Runner)? = nil) async throws -> MaterializedTemplate {
    let mt = try await store.getMountTemplate(identifier: identifier)

    // When a non-local runner is provided, materialize on the runner's filesystem.
    // The template's paths (templatePath, workspacesPath) are interpreted on the runner.
    if let runner, runner.id != .local {
      let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(mt.workspacesPath, cwd: "")
      let destinationPath = URL(fileURLWithPath: workspacesRoot)
        .appendingPathComponent(sessionID, isDirectory: true)
        .path
      let response = try await runner.materialize(params: MaterializeRequest(
        templatePath: mt.templatePath,
        destinationPath: destinationPath,
        startupScript: mt.startupScript,
      ))
      return MaterializedTemplate(templateID: mt.id, workspacePath: response.workspacePath)
    }

    // Local materialization (existing behavior)
    let serverCwd = FileManager.default.currentDirectoryPath
    let templatePath = ToolPath.resolveToCwd(mt.templatePath, cwd: serverCwd)
    let workspacesRoot = WuhuWorkspaceManager.resolveWorkspacesPath(mt.workspacesPath)
    let workspacePath = try await WuhuWorkspaceManager.materializeFolderTemplateWorkspace(
      sessionID: sessionID,
      templatePath: templatePath,
      startupScript: mt.startupScript,
      workspacesPath: workspacesRoot,
    )
    return MaterializedTemplate(templateID: mt.id, workspacePath: workspacePath)
  }

  private func createDirectSession(parentSessionID: String, mountTemplateIdentifier: String, task: String) async throws -> WuhuSession {
    let parent = try await store.getSession(id: parentSessionID)
    let settings = try await store.loadSettingsSnapshot(sessionID: .init(rawValue: parentSessionID))
    let reasoningEffort = settings.effectiveReasoningEffort

    let childSessionID = UUID().uuidString.lowercased()
    let resolved = try await materializeMountTemplate(identifier: mountTemplateIdentifier, sessionID: childSessionID)

    _ = try await createSession(
      sessionID: childSessionID,
      provider: parent.provider,
      model: parent.model,
      reasoningEffort: reasoningEffort,
      systemPrompt: WuhuDefaultSystemPrompts.codingAgent,
      cwd: resolved.workspacePath,
      parentSessionID: parentSessionID,
    )

    // Create mount record
    let mount = try await store.createMount(
      sessionID: childSessionID,
      name: mountTemplateIdentifier,
      path: resolved.workspacePath,
      mountTemplateID: resolved.templateID,
      isPrimary: true,
    )

    // Emit mount-level context
    try await emitMountContext(sessionID: childSessionID, mount: mount)

    // Enqueue the task
    let author: Author = .participant(.init(rawValue: "channel-agent"), kind: .bot)
    let message = QueuedUserMessage(author: author, content: .text(task))
    _ = try await enqueue(sessionID: .init(rawValue: childSessionID), message: message, lane: .followUp)

    return try await store.getSession(id: childSessionID)
  }

  // MARK: - list_runners tool

  private func listRunnersTool() -> AnyAgentTool {
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ])

    let tool = Tool(
      name: WuhuAgentToolNames.listRunners,
      description: "List all registered runners with their connection status. Shows built-in, declared (from server config), and incoming (connected to server) runners.",
      parameters: schema,
    )

    return AnyAgentTool(tool: tool, label: WuhuAgentToolNames.listRunners) { [weak self] _, _ in
      guard let self else { throw WuhuToolExecutionError(message: "Service unavailable") }

      let runners = await runnerRegistry.listAll()
      var lines: [String] = []
      for r in runners {
        let status = r.isConnected ? "connected" : "disconnected"
        lines.append("\(r.name)\t\(status)\t(\(r.source.rawValue))")
      }

      let output = lines.isEmpty ? "(no runners)" : lines.joined(separator: "\n")
      let details: JSONValue = .array(runners.map { r in
        .object([
          "name": .string(r.name),
          "source": .string(r.source.rawValue),
          "isConnected": .bool(r.isConnected),
        ])
      })

      return AgentToolResult(content: [.text(output)], details: details)
    }
  }
}
