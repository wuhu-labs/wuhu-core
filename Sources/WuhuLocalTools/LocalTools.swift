import Foundation
import PiAI
import Subprocess
import WuhuSessionCore

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

public struct LocalSessionProjection: Sendable, Hashable {
  public var title: String?

  public init(title: String? = nil) {
    self.title = title
  }

  public static func project(from transcript: Transcript) -> Self {
    var projection = Self()

    for entry in transcript.entries {
      guard case let .semantic(record) = entry else { continue }
      guard let semantic: SessionSemanticEntry = record.entry.unwrap() else { continue }

      switch semantic {
      case let .sessionTitleSet(title):
        projection.title = title
      }
    }

    return projection
  }
}

public struct LocalSessionObservation: Sendable, Hashable {
  public var state: AgentState
  public var projection: LocalSessionProjection

  public init(state: AgentState, projection: LocalSessionProjection) {
    self.state = state
    self.projection = projection
  }
}

public enum LocalSessionFactory {
  public static func makeBundle(
    configuration: SessionConfiguration = .init(),
    environment: SessionEnvironment = .current()
  ) -> SessionBundle<LocalSessionObservation> {
    let session = SessionActor(
      configuration: configuration,
      environment: environment,
      tools: makeToolRegistry()
    )

    return SessionBundle(
      session: session,
      makeObservation: {
        let stateStream = await session.subscribe()
        return AsyncStream { continuation in
          Task {
            for await state in stateStream {
              continuation.yield(
                .init(
                  state: state,
                  projection: .project(from: state.transcript)
                )
              )
            }
            continuation.finish()
          }
        }
      }
    )
  }

  public static func makeToolRegistry() -> ToolRegistry {
    SessionSemanticTools.makeRegistry().merging(makeLocalToolRegistry())
  }

  public static func makeLocalToolRegistry() -> ToolRegistry {
    let bash = bashTool()

    return ToolRegistry(
      exposedTools: [bash.tool],
      executors: [
        bash.tool.name: bash,
      ]
    )
  }

  private static func bashTool() -> AnyToolExecutor {
    struct Params: Decodable {
      var command: String
      var workingDirectory: String?
    }

    let tool = Tool(
      name: "bash",
      description: "Run a shell command on the local machine using zsh.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object([
            "type": .string("string"),
            "description": .string("The zsh command to execute."),
          ]),
          "workingDirectory": .object([
            "type": .string("string"),
            "description": .string("Optional absolute working directory."),
          ]),
        ]),
        "required": .array([.string("command")]),
        "additionalProperties": .bool(false),
      ])
    )

    return AnyToolExecutor(tool: tool, lifecycle: .runtime(.process)) { call in
      let params = try decode(Params.self, from: call.arguments)
      let command = params.command.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !command.isEmpty else {
        throw ToolError.message("command must not be empty")
      }

      let output = try await BashRunner.run(
        command: command,
        workingDirectory: params.workingDirectory
      )

      return ToolExecutionOutcome(
        result: .init(
          content: [.text(output.displayText)],
          details: .object([
            "command": .string(command),
            "workingDirectory": params.workingDirectory.map(JSONValue.string) ?? .null,
            "exitCode": .number(Double(output.exitCode)),
            "stdout": .string(output.stdout),
            "stderr": .string(output.stderr),
          ]),
          isError: output.exitCode != 0
        )
      )
    }
  }
}

private struct BashOutput {
  var stdout: String
  var stderr: String
  var exitCode: Int32

  var displayText: String {
    let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmedStdout.isEmpty, trimmedStderr.isEmpty {
      return "Command exited with status \(exitCode)."
    }
    if trimmedStderr.isEmpty {
      return trimmedStdout
    }
    if trimmedStdout.isEmpty {
      return "stderr:\n\(trimmedStderr)"
    }
    return "\(trimmedStdout)\n\nstderr:\n\(trimmedStderr)"
  }
}

private enum BashRunner {
  static func run(command: String, workingDirectory: String?) async throws -> BashOutput {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-local-bash-\(UUID().uuidString.lowercased()).log")
    _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)

    let outputFD = try FileDescriptor.open(
      FilePath(outputURL.path),
      .writeOnly,
      options: [.create, .truncate],
      permissions: [.ownerReadWrite, .groupRead, .otherRead]
    )

    var platformOptions = PlatformOptions()
    platformOptions.processGroupID = 0
    platformOptions.teardownSequence = [
      .send(signal: .terminate, allowedDurationToNextStep: .seconds(3)),
    ]

    let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
    let environment: Environment = .inherit.updating([
      "CI": "1",
      "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "dumb",
      "PAGER": "cat",
      "GIT_PAGER": "cat",
    ])

    let result = try await Subprocess.run(
      .path("/bin/zsh"),
      arguments: ["-lc", command],
      environment: environment,
      workingDirectory: FilePath(cwd),
      platformOptions: platformOptions,
      input: .none,
      output: .fileDescriptor(outputFD, closeAfterSpawningProcess: true),
      error: .fileDescriptor(outputFD, closeAfterSpawningProcess: false)
    ) { _ in () }

    let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: outputURL)

    let exitCode: Int32 = switch result.terminationStatus {
    case let .exited(code):
      code
    case let .unhandledException(signal):
      -signal
    }

    return BashOutput(
      stdout: output,
      stderr: "",
      exitCode: exitCode
    )
  }
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return try JSONDecoder().decode(type, from: data)
}
