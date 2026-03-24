import ArgumentParser
import Fetch
import FetchSSE
import Foundation
import WuhuAI
import WuhuAPI
import WuhuClient
import WuhuCLIKit
import WuhuCore
import WuhuCoreClient
import WuhuRunner
import WuhuServer
import Yams

extension WuhuProvider: ExpressibleByArgument {}
extension ReasoningEffort: @retroactive ExpressibleByArgument {}
extension WuhuMountTemplateType: ExpressibleByArgument {}

@main
struct WuhuCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "wuhu",
    abstract: "Wuhu – server + client for persisted coding-agent sessions.",
    version: "wuhu \(WuhuVersion.display)",
    subcommands: [
      Server.self,
      Client.self,
      RunnerCommand.self,
      VersionCommand.self,
      UpgradeCommand.self,
    ],
  )

  struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "server",
      abstract: "Run the Wuhu HTTP server.",
    )

    @Option(help: "Path to server config YAML (default: ~/.wuhu/server.yml).")
    var config: String?

    @Option(help: "If set, dump all LLM requests/responses to this directory (JSON, ordered by time).")
    var llmRequestLogDir: String?

    func run() async throws {
      try await WuhuServer().run(configPath: config, llmRequestLogDir: llmRequestLogDir)
    }
  }

  struct RunnerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "runner",
      abstract: "Run a Wuhu runner (accepts connections from a Wuhu server).",
    )

    @Option(help: "Path to runner config YAML (default: ~/.wuhu/runner.yml).")
    var config: String?

    func run() async throws {
      try await WuhuMuxRunnerServer().run(configPath: config)
    }
  }

  struct Client: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "client",
      abstract: "Client commands (talk to a running Wuhu server).",
      subcommands: [
        CreateSession.self,
        SetModel.self,
        Prompt.self,
        StopSession.self,
        GetSession.self,
        ListProfiles.self,
        ListSkills.self,
        ListSessions.self,
        SessionGroup.self,
        Workspace.self,
        User.self,
        Channel.self,
      ],
    )

    struct Shared: ParsableArguments {
      @Option(help: "Server base URL (default: read ~/.wuhu/client.yml, else http://127.0.0.1:5530).")
      var server: String?

      @Option(help: "Username for prompts (default: WUHU_USERNAME, else ~/.wuhu/client.yml username, else <osuser>@<hostname>).")
      var username: String?

      @Option(help: "Session output verbosity (full, compact, minimal).")
      var verbosity: SessionOutputVerbosity = .full
    }

    struct CreateSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "create-session",
        abstract: "Create a new persisted session.",
      )

      @Option(help: "Provider for this session.")
      var provider: WuhuProvider

      @Option(help: "Model id (server defaults depend on provider).")
      var model: String?

      @Option(help: "Reasoning effort (minimal, low, medium, high, xhigh). Only applies to some OpenAI/Codex models.")
      var reasoningEffort: ReasoningEffort?

      @Option(help: "Mount template identifier (UUID or unique name).")
      var mountTemplate: String?

      @Option(help: "Direct path to mount.")
      var mountPath: String?

      @Option(help: "Session group id (defaults to Inbox).")
      var sessionGroupId: String?

      @Option(help: "System prompt override (optional).")
      var systemPrompt: String?

      @Option(help: "Parent session id (optional).")
      var parentSessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let session = try await client.createSession(.init(
          provider: provider,
          model: model,
          reasoningEffort: reasoningEffort,
          systemPrompt: systemPrompt,
          mountTemplate: mountTemplate,
          mountPath: mountPath,
          sessionGroupID: sessionGroupId,
          parentSessionID: parentSessionId,
        ))
        FileHandle.standardOutput.write(Data("\(session.id)\n".utf8))
      }
    }

    struct Prompt: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Append a prompt to a session and stream the assistant response.",
      )

      @Option(help: "Session id returned by create-session (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @Argument(parsing: .remaining, help: "Prompt text.")
      var prompt: [String] = []

      @Option(name: .long, help: "Path to an image file to attach. Can be specified multiple times.")
      var image: [String] = []

      @Flag(help: "Send the prompt and return immediately (do not wait for the agent to finish).")
      var detach: Bool = false

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let username = resolveWuhuUsername(shared.username)

        let text = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !image.isEmpty

        guard !text.isEmpty || hasImages else { throw ValidationError("Expected a prompt.") }

        var imageAttachments: [(data: Data, mimeType: String)] = []
        for path in image {
          let fileURL = URL(fileURLWithPath: path)
          let ext = fileURL.pathExtension.lowercased()

          guard WuhuBlobStore.isImageExtension(ext) else {
            throw ValidationError("Unsupported image format: \(ext). Supported: png, jpg, jpeg, gif, webp")
          }

          guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("Image file not found: \(path)")
          }

          let data = try Data(contentsOf: fileURL)
          guard data.count <= WuhuBlobStore.maxImageFileSize else {
            throw ValidationError("Image file too large: \(path). Max: 10MB")
          }

          guard let mimeType = WuhuBlobStore.mimeTypeForExtension(ext) else {
            throw ValidationError("Unsupported image format: \(ext). Supported: png, jpg, jpeg, gif, webp")
          }

          imageAttachments.append((data: data, mimeType: mimeType))
        }

        let content: MessageContent
        if hasImages {
          var imageParts: [MessageContentPart] = []
          for attachment in imageAttachments {
            let blobURI = try await client.uploadBlob(
              sessionID: sessionId,
              data: attachment.data,
              mimeType: attachment.mimeType,
            )
            imageParts.append(.image(blobURI: blobURI, mimeType: attachment.mimeType))
          }
          let promptText = text.isEmpty ? "(see attached image)" : text
          content = .richContent([.text(promptText)] + imageParts)
        } else {
          content = .text(text)
        }

        let terminal = TerminalCapabilities()
        var printer = SessionStreamPrinter(
          style: .init(verbosity: shared.verbosity, terminal: terminal),
        )

        if detach {
          let qid = try await client.enqueue(sessionID: sessionId, content: content, user: username, lane: .followUp)
          FileHandle.standardOutput.write(Data("enqueued  id=\(qid)\n".utf8))
          return
        }

        let baseline = try await client.getSession(id: sessionId)
        let sinceCursor = baseline.transcript.last?.id
        _ = try await client.enqueue(sessionID: sessionId, content: content, user: username, lane: .followUp)
        let stream = try await client.followSessionStream(
          sessionID: sessionId,
          sinceCursor: sinceCursor,
          sinceTime: nil,
          stopAfterIdle: true,
          timeoutSeconds: nil,
        )

        for try await event in stream {
          printer.handle(event)
        }
      }
    }

    struct SetModel: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "set-model",
        abstract: "Change the model selection for an existing session.",
      )

      @Option(help: "Session id returned by create-session (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @Option(help: "Provider for this session.")
      var provider: WuhuProvider

      @Option(help: "Model id (server defaults depend on provider).")
      var model: String?

      @Option(help: "Reasoning effort (minimal, low, medium, high, xhigh). Only applies to some OpenAI/Codex models.")
      var reasoningEffort: ReasoningEffort?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let response = try await client.setSessionModel(
          sessionID: sessionId,
          provider: provider,
          model: model,
          reasoningEffort: reasoningEffort,
        )

        let effort = response.selection.reasoningEffort?.rawValue ?? "default"
        let status = response.applied ? "applied" : "pending"
        FileHandle.standardOutput.write(
          Data("\(status)  \(response.selection.provider.rawValue)  \(response.selection.model)  reasoning=\(effort)\n".utf8),
        )
      }
    }

    struct StopSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "stop-session",
        abstract: "Stop the current session execution, if any.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)
        let username = resolveWuhuUsername(shared.username)

        let response = try await client.stopSession(sessionID: sessionId, user: username)
        if let stopEntry = response.stopEntry {
          FileHandle.standardOutput.write(
            Data("stopped  cursor=\(stopEntry.id)  repaired=\(response.repairedEntries.count)\n".utf8),
          )
        } else {
          FileHandle.standardOutput.write(Data("idle\n".utf8))
        }
      }
    }

    struct GetSession: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "get-session",
        abstract: "Print session metadata and full transcript.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @Option(help: "Only include transcript entries after this cursor id (exclusive).")
      var sinceCursor: Int64?

      @Option(help: "Only include transcript entries after this time. Accepts unix seconds, ISO-8601, or 'yyyy/MM/dd HH:mm:ss[Z]'.")
      var sinceTime: String?

      @Flag(help: "Follow live updates to the session over SSE.")
      var follow: Bool = false

      @Flag(help: "In follow mode, stop once the session becomes idle.")
      var stopAfterIdle: Bool = false

      @Option(help: "In follow mode, stop after this many seconds.")
      var timeoutSeconds: Double?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)

        let parsedSinceTime = try sinceTime.flatMap(parseSinceTime)

        if follow {
          let terminal = TerminalCapabilities()
          var printer = SessionStreamPrinter(style: .init(verbosity: shared.verbosity, terminal: terminal))

          let effectiveStopAfterIdle = stopAfterIdle || (timeoutSeconds == nil)
          let stream = try await client.followSessionStream(
            sessionID: sessionId,
            sinceCursor: sinceCursor,
            sinceTime: parsedSinceTime,
            stopAfterIdle: effectiveStopAfterIdle,
            timeoutSeconds: timeoutSeconds,
          )

          for try await event in stream {
            printer.handle(event)
          }
          return
        }

        let response = try await client.getSession(id: sessionId, sinceCursor: sinceCursor, sinceTime: parsedSinceTime)

        let terminal = TerminalCapabilities()
        let style = SessionOutputStyle(verbosity: shared.verbosity, terminal: terminal)
        let renderer = SessionTranscriptRenderer(style: style)
        FileHandle.standardOutput.write(Data(renderer.render(response).utf8))
      }
    }

    struct ListSkills: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list-skills",
        abstract: "List skills loaded into a session's context.",
      )

      @Option(help: "Session id (or set WUHU_CURRENT_SESSION_ID).")
      var sessionId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessionId = try resolveWuhuSessionId(sessionId)

        let response = try await client.getSession(id: sessionId)
        let skills = WuhuSkills.extract(from: response.transcript)

        if skills.isEmpty {
          FileHandle.standardOutput.write(Data("(no skills)\n".utf8))
          return
        }

        for skill in skills {
          FileHandle.standardOutput.write(Data("\(skill.name)\t\(skill.description)\t\(skill.filePath)\n".utf8))
        }
      }
    }

    struct ListProfiles: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list-profiles",
        abstract: "List workspace profiles discovered under _profiles/.",
      )

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let profiles = try await client.listProfiles()
        for profile in profiles {
          FileHandle.standardOutput.write(Data("\(profile.name)\t\(profile.agentsPath)\n".utf8))
        }
      }
    }

    struct ListSessions: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list-sessions",
        abstract: "List sessions.",
      )

      @Option(help: "Max sessions to list.")
      var limit: Int?

      @Flag(help: "Include archived sessions.")
      var includeArchived = false

      @Option(help: "Only list sessions from this session group id.")
      var sessionGroupId: String?

      @OptionGroup
      var shared: Shared

      func run() async throws {
        let client = try makeClient(shared.server)
        let sessions = try await client.listSessions(
          limit: limit,
          includeArchived: includeArchived,
          sessionGroupID: sessionGroupId,
        )
        for summary in sessions {
          let session = summary.session
          let cwdStr = session.cwd ?? "(no mount)"
          let lastMessage = summary.lastMessageText ?? "(no messages yet)"
          FileHandle.standardOutput.write(
            Data(
              "\(session.id)\tgroup=\(session.sessionGroupID)\t\(summary.displayTitle)\t\(session.provider.rawValue)\t\(session.model)\tcwd=\(cwdStr)\tlast=\(lastMessage)\tupdatedAt=\(session.updatedAt)\n".utf8,
            ),
          )
        }
      }
    }

    struct SessionGroup: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "session-group",
        abstract: "Session group commands.",
        subcommands: [
          List.self,
          Create.self,
          Update.self,
        ],
      )

      struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "list",
          abstract: "List session groups.",
        )

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let groups = try await client.listSessionGroups()
          for group in groups {
            let profile = group.profileName ?? "(workspace default)"
            let marker = group.isDefault ? " default" : ""
            FileHandle.standardOutput.write(Data("\(group.id)\t\(group.name)\tprofile=\(profile)\(marker)\n".utf8))
          }
        }
      }

      struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "create",
          abstract: "Create a session group.",
        )

        @Option(help: "Group name.")
        var name: String

        @Option(help: "Optional profile name under _profiles/.")
        var profile: String?

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let group = try await client.createSessionGroup(.init(name: name, profileName: profile))
          FileHandle.standardOutput.write(Data("\(group.id)\n".utf8))
        }
      }

      struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "update",
          abstract: "Rename a session group or change its profile.",
        )

        @Argument(help: "Session group id.")
        var id: String

        @Option(help: "New group name.")
        var name: String

        @Option(help: "Optional profile name under _profiles/. Use an empty string to clear.")
        var profile: String?

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let normalizedProfile = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
          let request = WuhuUpdateSessionGroupRequest(
            name: name,
            profileName: normalizedProfile?.isEmpty == true ? nil : normalizedProfile,
          )
          let group = try await client.updateSessionGroup(id: id, request: request)
          let profileText = group.profileName ?? "(workspace default)"
          FileHandle.standardOutput.write(Data("\(group.id)\t\(group.name)\tprofile=\(profileText)\n".utf8))
        }
      }
    }

    struct Workspace: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Workspace document commands.",
        subcommands: [
          Tree.self,
          Read.self,
          Query.self,
        ],
      )

      struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "tree",
          abstract: "Show the workspace directory tree.",
        )

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let tree = try await client.workspaceTree()
          printTree(tree, indent: 0)
        }

        private func printTree(_ node: WuhuAPI.DirectoryNode, indent: Int) {
          let prefix = String(repeating: "  ", count: indent)
          let name = node.path.isEmpty ? "(root)" : node.name
          let indexMarker = node.hasIndex ? " [index]" : ""
          FileHandle.standardOutput.write(Data("\(prefix)\(name)/\(indexMarker)\n".utf8))
          for child in node.children {
            printTree(child, indent: indent + 1)
          }
        }
      }

      struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "read",
          abstract: "Read a workspace document.",
        )

        @Argument(help: "Workspace-relative path to the document (e.g., docs/readme.md, issues/_index.md).")
        var path: String

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let doc = try await client.readWorkspaceDoc(path: path)
          // Print frontmatter summary.
          if !doc.frontmatter.isEmpty {
            FileHandle.standardOutput.write(Data("--- frontmatter ---\n".utf8))
            for (key, value) in doc.frontmatter.sorted(by: { $0.key < $1.key }) {
              FileHandle.standardOutput.write(Data("\(key): \(value)\n".utf8))
            }
            FileHandle.standardOutput.write(Data("---\n\n".utf8))
          }
          FileHandle.standardOutput.write(Data(doc.body.utf8))
          if !doc.body.hasSuffix("\n") {
            FileHandle.standardOutput.write(Data("\n".utf8))
          }
        }
      }

      struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "query",
          abstract: "Run a raw SQL query against the workspace engine.",
        )

        @Argument(help: "SQL query to execute.")
        var sql: String

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let rows = try await client.workspaceQuery(sql: sql)
          if rows.isEmpty {
            FileHandle.standardOutput.write(Data("(no results)\n".utf8))
            return
          }
          // Collect all column names from the first row.
          let columns = rows[0].keys.sorted()
          // Print header.
          FileHandle.standardOutput.write(Data((columns.joined(separator: "\t") + "\n").utf8))
          // Print rows.
          for row in rows {
            let values = columns.map { row[$0] ?? "NULL" }
            FileHandle.standardOutput.write(Data((values.joined(separator: "\t") + "\n").utf8))
          }
        }
      }
    }

    // MARK: - User commands

    struct User: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "User management commands.",
        subcommands: [
          ListUsers.self,
          CreateUser.self,
          DeleteUser.self,
        ],
      )

      struct ListUsers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "list",
          abstract: "List all users.",
        )

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let users = try await client.listUsers()
          if users.isEmpty {
            FileHandle.standardOutput.write(Data("(no users)\n".utf8))
            return
          }
          for u in users {
            FileHandle.standardOutput.write(Data("\(u.id)  \(u.username)  kind=\(u.kind.rawValue)  created=\(u.createdAt)\n".utf8))
          }
        }
      }

      struct CreateUser: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "create",
          abstract: "Create a new user.",
        )

        @Argument(help: "Username.")
        var username: String

        @Option(help: "User kind (human, bot). Default: human.")
        var kind: String = "human"

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let userKind = WuhuUserKind(rawValue: kind) ?? .human
          let user = try await client.createUser(username: username, kind: userKind)
          FileHandle.standardOutput.write(Data("\(user.id)  \(user.username)  kind=\(user.kind.rawValue)\n".utf8))
        }
      }

      struct DeleteUser: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "delete",
          abstract: "Delete a user by ID.",
        )

        @Argument(help: "User ID.")
        var id: String

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          try await client.deleteUser(id: id)
          FileHandle.standardOutput.write(Data("deleted\n".utf8))
        }
      }
    }

    // MARK: - Channel commands

    struct Channel: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "channel",
        abstract: "Channel management commands.",
        subcommands: [
          ListChannels.self,
          CreateChannel.self,
          DeleteChannel.self,
          Members.self,
          Send.self,
          History.self,
          Follow.self,
        ],
      )

      struct ListChannels: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "list",
          abstract: "List all channels.",
        )

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let channels = try await client.listChannels()
          if channels.isEmpty {
            FileHandle.standardOutput.write(Data("(no channels)\n".utf8))
            return
          }
          for ch in channels {
            let topicStr = ch.topic.map { " topic=\"\($0)\"" } ?? ""
            FileHandle.standardOutput.write(Data("\(ch.id)  #\(ch.name)  kind=\(ch.kind.rawValue)\(topicStr)\n".utf8))
          }
        }
      }

      struct CreateChannel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "create",
          abstract: "Create a new channel.",
        )

        @Argument(help: "Channel name.")
        var name: String

        @Option(help: "Channel topic.")
        var topic: String?

        @Option(help: "Channel kind (channel, dm). Default: channel.")
        var kind: String = "channel"

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let channelKind = WuhuChannelKind(rawValue: kind) ?? .channel
          let channel = try await client.createChannel(name: name, topic: topic, kind: channelKind)
          FileHandle.standardOutput.write(Data("\(channel.id)  #\(channel.name)\n".utf8))
        }
      }

      struct DeleteChannel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "delete",
          abstract: "Delete a channel by ID.",
        )

        @Argument(help: "Channel ID.")
        var id: String

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          try await client.deleteChannel(id: id)
          FileHandle.standardOutput.write(Data("deleted\n".utf8))
        }
      }

      struct Members: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "members",
          abstract: "List, add, or remove channel members.",
          subcommands: [
            ListMembers.self,
            AddMember.self,
            RemoveMember.self,
          ],
        )

        struct ListMembers: AsyncParsableCommand {
          static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List members of a channel.",
          )

          @Argument(help: "Channel ID.")
          var channelID: String

          @OptionGroup
          var shared: Shared

          func run() async throws {
            let client = try makeClient(shared.server)
            let members = try await client.listChannelMembers(channelID: channelID)
            if members.isEmpty {
              FileHandle.standardOutput.write(Data("(no members)\n".utf8))
              return
            }
            for m in members {
              FileHandle.standardOutput.write(Data("\(m.userID)  \(m.username)  role=\(m.role.rawValue)\n".utf8))
            }
          }
        }

        struct AddMember: AsyncParsableCommand {
          static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a member to a channel.",
          )

          @Argument(help: "Channel ID.")
          var channelID: String

          @Argument(help: "User ID to add.")
          var userID: String

          @Option(help: "Role (member, admin). Default: member.")
          var role: String = "member"

          @OptionGroup
          var shared: Shared

          func run() async throws {
            let client = try makeClient(shared.server)
            let memberRole = WuhuChannelMemberRole(rawValue: role) ?? .member
            let member = try await client.addChannelMember(channelID: channelID, userID: userID, role: memberRole)
            FileHandle.standardOutput.write(Data("added  \(member.username)  role=\(member.role.rawValue)\n".utf8))
          }
        }

        struct RemoveMember: AsyncParsableCommand {
          static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a member from a channel.",
          )

          @Argument(help: "Channel ID.")
          var channelID: String

          @Argument(help: "User ID to remove.")
          var userID: String

          @OptionGroup
          var shared: Shared

          func run() async throws {
            let client = try makeClient(shared.server)
            try await client.removeChannelMember(channelID: channelID, userID: userID)
            FileHandle.standardOutput.write(Data("removed\n".utf8))
          }
        }
      }

      struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "send",
          abstract: "Send a message to a channel.",
        )

        @Argument(help: "Channel ID.")
        var channelID: String

        @Argument(parsing: .remaining, help: "Message text.")
        var message: [String] = []

        @Option(help: "Thread parent message ID (for replies).")
        var thread: Int64?

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let text = message.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { throw ValidationError("Expected message text.") }
          let username = resolveWuhuUsername(shared.username)
          let msg = try await client.postChannelMessage(
            channelID: channelID,
            content: text,
            threadID: thread,
            username: username,
          )
          FileHandle.standardOutput.write(Data("[\(msg.id)] \(msg.authorUsername): \(msg.content)\n".utf8))
        }
      }

      struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "history",
          abstract: "Show channel message history.",
        )

        @Argument(help: "Channel ID.")
        var channelID: String

        @Option(help: "Max messages to show.")
        var limit: Int = 50

        @Option(help: "Show messages before this message ID.")
        var before: Int64?

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)
          let messages = try await client.listChannelMessages(channelID: channelID, before: before, limit: limit)
          if messages.isEmpty {
            FileHandle.standardOutput.write(Data("(no messages)\n".utf8))
            return
          }
          for msg in messages {
            let threadStr = msg.threadID.map { " (thread:\($0))" } ?? ""
            FileHandle.standardOutput.write(Data("[\(msg.id)] \(msg.authorUsername): \(msg.content)\(threadStr)\n".utf8))
          }
        }
      }

      struct Follow: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          commandName: "follow",
          abstract: "Follow a channel in real-time via SSE.",
        )

        @Argument(help: "Channel ID.")
        var channelID: String

        @Option(help: "Show messages after this message ID.")
        var since: Int64?

        @OptionGroup
        var shared: Shared

        func run() async throws {
          let client = try makeClient(shared.server)

          var url = client.baseURL
            .appending(path: "v1")
            .appending(path: "channels")
            .appending(path: channelID)
            .appending(path: "subscribe")

          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
          var items: [URLQueryItem] = []
          if let since { items.append(.init(name: "messageSince", value: String(since))) }
          components?.queryItems = items.isEmpty ? nil : items
          url = components?.url ?? url

          var req = Request(url: url, method: "GET")
          req.setHeader("text/event-stream", for: "Accept")

          let response = try await sharedFetchClient(req)
          try response.validateStatus()

          for try await message in response.sse() {
            guard let data = message.data.data(using: .utf8) else { continue }
            let frame = try WuhuJSON.decoder.decode(ChannelSubscriptionSSEFrame.self, from: data)

            switch frame {
            case let .initial(state):
              FileHandle.standardOutput.write(Data("--- #\(state.channel.name) ---\n".utf8))
              if !state.members.isEmpty {
                let names = state.members.map(\.username).joined(separator: ", ")
                FileHandle.standardOutput.write(Data("members: \(names)\n".utf8))
              }
              FileHandle.standardOutput.write(Data("---\n".utf8))
              for msg in state.messages {
                let threadStr = msg.threadID.map { " (thread:\($0))" } ?? ""
                FileHandle.standardOutput.write(Data("[\(msg.id)] \(msg.authorUsername): \(msg.content)\(threadStr)\n".utf8))
              }

            case let .event(event):
              switch event {
              case let .messagePosted(msg):
                let threadStr = msg.threadID.map { " (thread:\($0))" } ?? ""
                FileHandle.standardOutput.write(Data("[\(msg.id)] \(msg.authorUsername): \(msg.content)\(threadStr)\n".utf8))
              case let .memberJoined(member):
                FileHandle.standardOutput.write(Data("* \(member.username) joined\n".utf8))
              case let .memberLeft(userID):
                FileHandle.standardOutput.write(Data("* \(userID) left\n".utf8))
              case let .channelUpdated(channel):
                let topicStr = channel.topic.map { " topic=\"\($0)\"" } ?? ""
                FileHandle.standardOutput.write(Data("* channel updated: #\(channel.name)\(topicStr)\n".utf8))
              }
            }
          }
        }
      }
    }
  }
}

private struct WuhuClientConfig: Sendable, Codable {
  var server: String?
  var username: String?
}

private func loadClientConfig() -> WuhuClientConfig? {
  let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".wuhu/client.yml")
    .path
  guard FileManager.default.fileExists(atPath: path) else { return nil }
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  return try? YAMLDecoder().decode(WuhuClientConfig.self, from: text)
}

private func makeClient(_ baseOverride: String?) throws -> WuhuClient {
  let base: String = {
    if let baseOverride, !baseOverride.isEmpty { return baseOverride }
    if let cfg = loadClientConfig(), let server = cfg.server, !server.isEmpty { return server }
    return "http://127.0.0.1:5530"
  }()

  guard let url = URL(string: base) else { throw ValidationError("Invalid server URL: \(base)") }
  return WuhuClient(baseURL: url)
}

private func printJSON(_ value: some Encodable) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .secondsSince1970
  let data = try encoder.encode(value)
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

func resolveWuhuSessionId(
  _ optionValue: String?,
  env: [String: String] = ProcessInfo.processInfo.environment,
) throws -> String {
  if let optionValue {
    let trimmed = optionValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  if let envValue = env["WUHU_CURRENT_SESSION_ID"] {
    let trimmed = envValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
  }
  throw ValidationError("Missing session id. Pass --session-id or set WUHU_CURRENT_SESSION_ID.")
}

func resolveWuhuUsername(
  _ optionValue: String?,
  env: [String: String] = ProcessInfo.processInfo.environment,
) -> String {
  func cleaned(_ raw: String?) -> String? {
    let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  if let opt = cleaned(optionValue) { return opt }
  if let envValue = cleaned(env["WUHU_USERNAME"]) { return envValue }
  if let cfg = loadClientConfig(), let cfgValue = cleaned(cfg.username) { return cfgValue }

  let user = cleaned(env["USER"]) ?? cleaned(env["USERNAME"]) ?? cleaned(NSUserName()) ?? "unknown_user"
  let host = cleaned(ProcessInfo.processInfo.hostName) ?? "unknown_host"
  return "\(user)@\(host)"
}

func parseSinceTime(_ raw: String) throws -> Date {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    throw ValidationError("Invalid --since-time (empty).")
  }

  if let seconds = Double(trimmed) {
    return Date(timeIntervalSince1970: seconds)
  }

  let iso = ISO8601DateFormatter()
  if let date = iso.date(from: trimmed) {
    return date
  }

  let fmt = DateFormatter()
  fmt.locale = Locale(identifier: "en_US_POSIX")

  if trimmed.hasSuffix("Z") {
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy/MM/dd HH:mm:ss'Z'"
    if let date = fmt.date(from: trimmed) { return date }
  }

  fmt.timeZone = TimeZone.current
  fmt.dateFormat = "yyyy/MM/dd HH:mm:ss"
  if let date = fmt.date(from: trimmed) { return date }

  throw ValidationError("Invalid --since-time value: \(raw)")
}
