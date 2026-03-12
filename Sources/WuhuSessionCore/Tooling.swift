import Foundation
import PiAI

public struct ToolCallResult: Sendable, Hashable {
  public var content: [ContentBlock]
  public var details: JSONValue
  public var isError: Bool

  public init(content: [ContentBlock], details: JSONValue = .object([:]), isError: Bool = false) {
    self.content = content
    self.details = details
    self.isError = isError
  }
}

public struct ToolExecutionOutcome: Sendable, Hashable {
  public var result: ToolCallResult
  public var semanticEntries: [AnySemanticEntry]

  public init(result: ToolCallResult, semanticEntries: [AnySemanticEntry] = []) {
    self.result = result
    self.semanticEntries = semanticEntries
  }
}

public enum ToolLifecycle: Sendable, Hashable {
  case immediate
  case runtime(ToolRuntimeKind)
}

public struct AnyToolExecutor: Sendable {
  public var tool: Tool
  public var lifecycle: ToolLifecycle
  private let _execute: @Sendable (ToolCall) async throws -> ToolExecutionOutcome

  public init(
    tool: Tool,
    lifecycle: ToolLifecycle = .immediate,
    execute: @escaping @Sendable (ToolCall) async throws -> ToolExecutionOutcome
  ) {
    self.tool = tool
    self.lifecycle = lifecycle
    self._execute = execute
  }

  public func execute(_ call: ToolCall) async throws -> ToolExecutionOutcome {
    try await _execute(call)
  }
}

public struct ToolRegistry: Sendable {
  public var exposedTools: [Tool]
  private var executors: [String: AnyToolExecutor]

  public init(exposedTools: [Tool], executors: [String: AnyToolExecutor]) {
    self.exposedTools = exposedTools
    self.executors = executors
  }

  public func lookup(_ name: String) -> AnyToolExecutor? {
    executors[name]
  }

  public func merging(_ other: ToolRegistry) -> ToolRegistry {
    var mergedExecutors = executors
    for (name, executor) in other.executors {
      mergedExecutors[name] = executor
    }

    let mergedTools = exposedTools + other.exposedTools.filter { tool in
      !exposedTools.contains(where: { $0.name == tool.name })
    }

    return ToolRegistry(
      exposedTools: mergedTools,
      executors: mergedExecutors
    )
  }
}

public enum SessionSemanticEntry: Sendable, Hashable, SemanticEntry {
  case sessionTitleSet(String)
}

public enum SessionSemanticTools {
  public static func makeRegistry() -> ToolRegistry {
    let setSessionTitle = setSessionTitleTool()
    return ToolRegistry(
      exposedTools: [setSessionTitle.tool],
      executors: [
        setSessionTitle.tool.name: setSessionTitle,
      ]
    )
  }

  private static func setSessionTitleTool() -> AnyToolExecutor {
    struct Params: Decodable {
      var title: String
    }

    let tool = Tool(
      name: "set_session_title",
      description: "Set the current session title for the app UI.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "title": .object([
            "type": .string("string"),
            "description": .string("The new title for this session."),
          ]),
        ]),
        "required": .array([.string("title")]),
        "additionalProperties": .bool(false),
      ])
    )

    return AnyToolExecutor(tool: tool) { call in
      let params = try decode(Params.self, from: call.arguments)
      let trimmed = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw ToolError.message("title must not be empty")
      }

      return ToolExecutionOutcome(
        result: .init(
          content: [.text("Session title set to \"\(trimmed)\".")],
          details: .object([
            "title": .string(trimmed),
          ])
        ),
        semanticEntries: [
          AnySemanticEntry(SessionSemanticEntry.sessionTitleSet(trimmed))
        ]
      )
    }
  }
}

public struct SessionBundle<Observation> {
  public let session: SessionActor
  public let makeObservation: @Sendable () async -> AsyncStream<Observation>

  public init(
    session: SessionActor,
    makeObservation: @escaping @Sendable () async -> AsyncStream<Observation>
  ) {
    self.session = session
    self.makeObservation = makeObservation
  }
}

public enum ToolError: Error, LocalizedError, Sendable {
  case message(String)

  public var errorDescription: String? {
    switch self {
    case let .message(message):
      message
    }
  }
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return try JSONDecoder().decode(type, from: data)
}
