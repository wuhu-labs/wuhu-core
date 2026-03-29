import Dependencies
import Foundation
import WuhuAI

public protocol FoundationTool {
    associatedtype Arguments: Equatable, Codable, Sendable
    associatedtype Result: Equatable, Codable, Sendable

    static var toolName: String { get }
    static func execute(arguments: Arguments, context: FoundationToolExecutionContext) async throws -> DeferredExecution<FoundationTools.Action>
}

public struct FoundationToolExecutionContext: Sendable {
    public var state: FoundationTools.State
    public var toolCall: ToolCall
    public var send: @Sendable (FoundationTools.Action) -> Void

    @Dependency(\.date)
    var date

    public func resolveRunnerID(mount: String?, runner: String?, state: FoundationTools.State) throws -> RunnerID {
        if let providedMount = mount {
            let mount = state.mounts.first { $0.name == providedMount }
            guard let mount else {
                throw FoundationTools.ValidationError.mountNotFound(providedMount)
            }
            return mount.runner
        } else if let providedRunner = runner {
            guard let parsedRunner = RunnerID(rawValue: providedRunner) else {
                throw FoundationTools.ValidationError.invalidRunnerID(providedRunner)
            }
            return parsedRunner
        } else {
            return .local
        }
    }

    public func resolveRunner(id runnerID: RunnerID) async throws -> Runner {
        throw FoundationTools.ExecutionError.runnerNotFound(runnerID)
    }

    public func run(
        body: @escaping @Sendable (
            _ send: @Sendable (FoundationTools.Action) -> Void,
        ) async throws -> FoundationToolResult.Content,
    ) -> DeferredExecution<FoundationTools.Action> {
        DeferredExecution { coordinator in
            do {
                let content = try await body(coordinator.send)
                coordinator.send(.toolCallDidFinish(makeToolCallResult(content: content)))
            } catch {
                coordinator.send(.toolCallDidFinish(makeToolCallResult(content: .error(String(describing: error)))))
            }
        }
    }

    func makeToolCallResult(content: FoundationToolResult.Content) -> FoundationToolResult {
        .init(toolCallId: toolCall.id, toolName: toolCall.name, content: content, timestamp: date())
    }
}

func resolveFoundationTool(name: String) throws -> any FoundationTool.Type {
    switch name {
    case ReadTool.toolName:
        return ReadTool.self
    default:
        throw FoundationToolCall.ParseError.unknownToolCall(name)
    }
}

public struct AnyFoundationToolResult: Equatable, Codable, Sendable {
    public var toolCallId: String
    public var toolName: String
    public var timestamp: Date

    let value: any (Equatable & Codable & Sendable)

    public static func == (lhs: AnyFoundationToolResult, rhs: AnyFoundationToolResult) -> Bool {
        guard lhs.toolCallId == rhs.toolCallId, lhs.toolName == rhs.toolName, lhs.timestamp == rhs.timestamp else {
            return false
        }
        return equals(lhs: lhs.value, rhs: rhs.value)
    }

    public enum CodingKeys: String, CodingKey {
        case toolCallId
        case toolName
        case timestamp
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(value, forKey: .value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        toolName = try container.decode(String.self, forKey: .toolName)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        let Tool = try resolveFoundationTool(name: toolName)
        let valueType = Tool.Result.self
        let x = try container.decode(Tool.Result.self, forKey: .value)
    }

    public func toContentBlock() -> [ContentBlock] {
        fatalError()
    }

    private static func equals<LHS: Equatable>(lhs: LHS, rhs: any Equatable) -> Bool {
        guard let rhs = rhs as? LHS else {
            return false
        }
        return lhs == rhs
    }
}
