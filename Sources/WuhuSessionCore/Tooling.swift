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

public enum PersistentToolEvent: Sendable, Hashable {
  case progress(String)
  case completed(ToolCallResult)
  case failed(String)
}

public struct PersistentToolSession: Sendable {
  public var events: AsyncStream<PersistentToolEvent>
  public var interrupt: @Sendable () async -> Void

  public init(events: AsyncStream<PersistentToolEvent>, interrupt: @escaping @Sendable () async -> Void) {
    self.events = events
    self.interrupt = interrupt
  }
}

public struct AnyNonPersistentTool: Sendable {
  public var tool: Tool
  private let _execute: @Sendable (ToolCall) async throws -> ToolCallResult

  public init(tool: Tool, execute: @escaping @Sendable (ToolCall) async throws -> ToolCallResult) {
    self.tool = tool
    self._execute = execute
  }

  public func execute(_ call: ToolCall) async throws -> ToolCallResult {
    try await _execute(call)
  }
}

public struct AnyPersistentTool: Sendable {
  public var tool: Tool
  private let _start: @Sendable (ToolCall) async throws -> PersistentToolSession

  public init(tool: Tool, start: @escaping @Sendable (ToolCall) async throws -> PersistentToolSession) {
    self.tool = tool
    self._start = start
  }

  public func start(_ call: ToolCall) async throws -> PersistentToolSession {
    try await _start(call)
  }
}

public enum RegisteredTool: Sendable {
  case nonPersistent(AnyNonPersistentTool)
  case persistent(AnyPersistentTool)
}

public struct ToolRegistry: Sendable {
  public var exposedTools: [Tool]
  private var executors: [String: RegisteredTool]

  public init(exposedTools: [Tool], executors: [String: RegisteredTool]) {
    self.exposedTools = exposedTools
    self.executors = executors
  }

  public func lookup(_ name: String) -> RegisteredTool? {
    executors[name]
  }
}

public struct VirtualFileSystem: Sendable, Hashable {
  public var files: [String: String]

  public init(files: [String: String]) {
    self.files = files
  }

  public func read(path rawPath: String) throws -> String {
    let normalized = Self.normalize(path: rawPath)
    guard let file = files[normalized] else {
      throw ToolError.message("File not found: \(normalized)")
    }
    return file
  }

  public static func normalize(path rawPath: String) -> String {
    var components: [String] = []
    for component in rawPath.split(separator: "/", omittingEmptySubsequences: false) {
      switch component {
      case "", ".":
        continue
      case "..":
        if !components.isEmpty {
          components.removeLast()
        }
      default:
        components.append(String(component))
      }
    }
    return "/" + components.joined(separator: "/")
  }
}

public extension VirtualFileSystem {
  static let seededPlayground = Self(
    files: [
      "/README.md": """
      # Wuhu Playground

      This is a seeded virtual file tree for the playground app.
      Use the read tool to inspect files.
      """,
      "/Specs/session.txt": """
      Sessions are in-memory in v1.
      Persistent tool progress is transient UI state.
      The transcript is append-only.
      """,
      "/Notes/today.md": """
      Build the cleanest possible first loop.
      Prefer readability over architecture astronautics.
      """
    ]
  )
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

public enum BuiltInTools {
  public static func makeRegistry(
    virtualFileSystem: VirtualFileSystem,
    sleepToolDriver: SleepToolDriver
  ) -> ToolRegistry {
    let read = readTool(virtualFileSystem: virtualFileSystem)
    let sleep = sleepTool(sleepToolDriver: sleepToolDriver)
    let join = joinTool()

    return ToolRegistry(
      exposedTools: [read.tool, sleep.tool, join],
      executors: [
        read.tool.name: .nonPersistent(read),
        sleep.tool.name: .persistent(sleep),
      ]
    )
  }

  public static func joinTool() -> Tool {
    Tool(
      name: "join",
      description: "Suspend until something interesting happens, then resume with a wake event result.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ])
    )
  }

  private static func readTool(virtualFileSystem: VirtualFileSystem) -> AnyNonPersistentTool {
    struct ReadParams: Decodable {
      var path: String
    }

    let tool = Tool(
      name: "read",
      description: "Read a text file from the playground virtual file system.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "path": .object([
            "type": .string("string"),
            "description": .string("Absolute or relative path inside the virtual file system."),
          ]),
        ]),
        "required": .array([.string("path")]),
        "additionalProperties": .bool(false),
      ])
    )

    return AnyNonPersistentTool(tool: tool) { call in
      let params = try decode(ReadParams.self, from: call.arguments)
      let file = try virtualFileSystem.read(path: params.path)
      return ToolCallResult(
        content: [.text(file)],
        details: .object([
          "path": .string(VirtualFileSystem.normalize(path: params.path)),
        ])
      )
    }
  }

  private static func sleepTool(sleepToolDriver: SleepToolDriver) -> AnyPersistentTool {
    struct SleepParams: Decodable {
      var minutes: Int
    }

    let tool = Tool(
      name: "sleep",
      description: "Wait for the requested number of minutes, emitting a transient progress update every minute before returning a final result.",
      parameters: .object([
        "type": .string("object"),
        "properties": .object([
          "minutes": .object([
            "type": .string("integer"),
            "description": .string("How many minutes to sleep."),
          ]),
        ]),
        "required": .array([.string("minutes")]),
        "additionalProperties": .bool(false),
      ])
    )

    return AnyPersistentTool(tool: tool) { call in
      let params = try decode(SleepParams.self, from: call.arguments)
      guard params.minutes >= 1 else {
        throw ToolError.message("minutes must be at least 1")
      }
      return try await sleepToolDriver.start(call.id, params.minutes)
    }
  }
}

private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
  let data = try JSONSerialization.data(withJSONObject: value.toAny())
  return try JSONDecoder().decode(type, from: data)
}
