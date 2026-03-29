import Dependencies
import Foundation
import WuhuAI

public protocol FoundationToolProtocol {
    associatedtype Arguments: Equatable, Codable, Sendable
    associatedtype Result: Equatable, Codable, Sendable

    static var toolName: String { get }
    static func execute(arguments: Arguments, context: FoundationToolExecutionContext) async throws -> DeferredExecution<FoundationTools.Action>
}

public enum FoundationTool {
    public enum Arguments: Equatable, Codable, Sendable {
        case read(ReadTool.Arguments)
    }

    public enum Result: Equatable, Codable, Sendable {
        case read(String)
    }

    public static func execute(arguments: Arguments, context: FoundationToolExecutionContext) async throws -> DeferredExecution<FoundationTools.Action> {
        switch arguments {
        case let .read(arguments):
            try await ReadTool.execute(arguments: arguments, context: context)
        }
    }
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
