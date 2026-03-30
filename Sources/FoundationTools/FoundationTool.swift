import AgentLoopModule
import Dependencies
import Foundation
import WuhuAI

public protocol FoundationToolProtocol {
  associatedtype Arguments: Equatable, Codable, Sendable
  associatedtype Result: Equatable, Codable, Sendable

  static var toolName: String { get }
  static func execute(arguments: Arguments, context: FoundationToolContext) throws -> ToolExecution
}

public extension FoundationToolProtocol {
  typealias ToolExecution = @Sendable (_ send: @Sendable (FoundationTool.Action) -> Void) async throws -> Result
}

public struct FoundationToolResult: Equatable, Codable, Sendable {
  public var toolCallId: String
  public var toolName: String
  public var timestamp: Date
  public var result: Result

  public enum Result: Equatable, Codable, Sendable {
    case success(FoundationTool.Result)
    case error(String)
  }

  public var isError: Bool {
    switch result {
    case .error:
      true
    default:
      false
    }
  }

  public func toContentBlock() -> [ContentBlock] {
    fatalError()
  }
}

public struct FoundationTool: Sendable {
  public init() {}

  public struct State: Equatable, Sendable {
    public var mounts: [Mount] = []
    public var startedToolCalls: Set<String> = []

    public init() {}
  }

  public enum Action: Sendable {
    case mount(MountTool.Result)
    case toolCallDidFinish(FoundationToolResult)
  }

  @Dependency(\.date)
  private var date

  public func reduce(action: Action, state: inout State) {
    switch action {
    case let .mount(mountResult):
      state.mounts.append(mountResult.mount)
    case let .toolCallDidFinish(result):
      state.startedToolCalls.remove(result.toolCallId)
    }
  }

  public func startToolCall(
    _ untypedToolCall: ToolCall,
    state: inout State,
  ) -> DeferredExecution<Action> {
    let context = FoundationToolContext(state: state, toolCall: untypedToolCall)
    do {
      let parsed = try Arguments.parse(untypedToolCall)
      if !state.startedToolCalls.contains(untypedToolCall.id) {
        state.startedToolCalls.insert(untypedToolCall.id)
      } else if !parsed.isRetryable {
        throw ExecutionError.toolCallResultLost(untypedToolCall.id)
      }

      return try execute(arguments: parsed, context: context)
    } catch {
      return .send(.toolCallDidFinish(context.makeToolError(error: error)))
    }
  }

  public enum Arguments: Equatable, Codable, Sendable {
    case read(ReadTool.Arguments)
    case write(WriteTool.Arguments)
    case edit(EditTool.Arguments)
    case ls(LsTool.Arguments)
    case rm(RmTool.Arguments)
    case grep(GrepTool.Arguments)
    case find(FindTool.Arguments)
    case bash(BashTool.Arguments)
    case mount(MountTool.Arguments)
    case park(ParkTool.Arguments)

    var isRetryable: Bool {
      switch self {
      case .read, .ls, .grep, .find:
        true
      default:
        false
      }
    }

    public static func parse(_ toolCall: ToolCall) throws -> Self {
      let decoder = JSONValueDecoder()

      switch toolCall.name {
      case ReadTool.toolName:
        return try .read(decoder.decode(ReadTool.Arguments.self, from: toolCall.arguments))
      case WriteTool.toolName:
        return try .write(decoder.decode(WriteTool.Arguments.self, from: toolCall.arguments))
      case EditTool.toolName:
        return try .edit(decoder.decode(EditTool.Arguments.self, from: toolCall.arguments))
      case LsTool.toolName:
        return try .ls(decoder.decode(LsTool.Arguments.self, from: toolCall.arguments))
      case RmTool.toolName:
        return try .rm(decoder.decode(RmTool.Arguments.self, from: toolCall.arguments))
      case GrepTool.toolName:
        return try .grep(decoder.decode(GrepTool.Arguments.self, from: toolCall.arguments))
      case FindTool.toolName:
        return try .find(decoder.decode(FindTool.Arguments.self, from: toolCall.arguments))
      case BashTool.toolName:
        return try .bash(decoder.decode(BashTool.Arguments.self, from: toolCall.arguments))
      case MountTool.toolName:
        return try .mount(decoder.decode(MountTool.Arguments.self, from: toolCall.arguments))
      case ParkTool.toolName:
        return try .park(decoder.decode(ParkTool.Arguments.self, from: toolCall.arguments))
      default:
        throw ParseError.unknownToolCall(toolCall.name)
      }
    }
  }

  public enum Result: Equatable, Codable, Sendable {
    case read(ReadTool.Result)
    case write(WriteTool.Result)
    case edit(EditTool.Result)
    case ls(LsTool.Result)
    case rm(RmTool.Result)
    case grep(GrepTool.Result)
    case find(FindTool.Result)
    case bash(BashTool.Result)
    case mount(MountTool.Result)
    case park(ParkTool.Result)
  }

  func executeBranch<T: FoundationToolProtocol>(
    of _: T.Type = T.self,
    arguments: T.Arguments,
    context: FoundationToolContext,
    embed: @escaping @Sendable (T.Result) -> Result,
  ) throws -> DeferredExecution<Action> {
    let execution = try T.execute(arguments: arguments, context: context)
    return DeferredExecution { coordinator in
      do {
        let result = try await embed(execution(coordinator.send))
        coordinator.send(.toolCallDidFinish(context.makeToolResult(result: result)))
      } catch {
        coordinator.send(.toolCallDidFinish(context.makeToolError(error: error)))
      }
    }
  }

  func execute(arguments: Arguments, context: FoundationToolContext) throws -> DeferredExecution<Action> {
    switch arguments {
    case let .read(arguments):
      try executeBranch(of: ReadTool.self, arguments: arguments, context: context, embed: Result.read)
    case let .write(arguments):
      try executeBranch(of: WriteTool.self, arguments: arguments, context: context, embed: Result.write)
    case let .edit(arguments):
      try executeBranch(of: EditTool.self, arguments: arguments, context: context, embed: Result.edit)
    case let .ls(arguments):
      try executeBranch(of: LsTool.self, arguments: arguments, context: context, embed: Result.ls)
    case let .rm(arguments):
      try executeBranch(of: RmTool.self, arguments: arguments, context: context, embed: Result.rm)
    case let .grep(arguments):
      try executeBranch(of: GrepTool.self, arguments: arguments, context: context, embed: Result.grep)
    case let .find(arguments):
      try executeBranch(of: FindTool.self, arguments: arguments, context: context, embed: Result.find)
    case let .bash(arguments):
      try executeBranch(of: BashTool.self, arguments: arguments, context: context, embed: Result.bash)
    case let .mount(arguments):
      try executeBranch(of: MountTool.self, arguments: arguments, context: context, embed: Result.mount)
    case let .park(arguments):
      try executeBranch(of: ParkTool.self, arguments: arguments, context: context, embed: Result.park)
    }
  }

  public enum ParseError: Error {
    case unknownToolCall(String)
  }

  public enum ValidationError: Error, Sendable {
    case duplicatedMountName(String)
    case mountNotFound(String)
    case invalidRunnerID(String)
  }

  public enum ExecutionError: Error, Sendable {
    case runnerNotFound(RunnerID)
    case toolCallResultLost(String)
  }
}

public struct FoundationToolContext: Sendable {
  public var state: FoundationTool.State
  public var toolCall: ToolCall

  @Dependency(\.date)
  var date
  @Dependency(FoundationExecutor.self)
  var foundationExecutor

  public func resolveRunnerID(mount: String?, runner: String?, state: FoundationTool.State) throws -> RunnerID {
    if let providedMount = mount {
      let mount = state.mounts.first { $0.name == providedMount }
      guard let mount else {
        throw FoundationTool.ValidationError.mountNotFound(providedMount)
      }
      return mount.runner
    } else if let providedRunner = runner {
      guard let parsedRunner = RunnerID(rawValue: providedRunner) else {
        throw FoundationTool.ValidationError.invalidRunnerID(providedRunner)
      }
      return parsedRunner
    } else {
      return .local
    }
  }

  public func resolveRunner(id: RunnerID) async throws -> Runner {
    try await foundationExecutor.resolveRunner(id: id)
  }

  func makeToolResult(result: FoundationTool.Result) -> FoundationToolResult {
    .init(toolCallId: toolCall.id, toolName: toolCall.name, timestamp: date(), result: .success(result))
  }

  func makeToolError(error: Error) -> FoundationToolResult {
    .init(toolCallId: toolCall.id, toolName: toolCall.name, timestamp: date(), result: .error(String(describing: error)))
  }
}
