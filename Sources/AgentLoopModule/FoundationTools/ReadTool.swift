public enum ReadTool: FoundationToolProtocol {
    public static var toolName: String {
        "read"
    }

    public struct Arguments: Equatable, Codable, Sendable {
        public var path: String
        public var mount: String?
        public var runner: String?
        public var offset: Int?
        public var limit: Int?
    }

    public typealias Result = String

    public static func execute(arguments: Arguments, context: FoundationToolExecutionContext) async throws -> DeferredExecution<FoundationTools.Action> {
        let runnerID = try context.resolveRunnerID(mount: arguments.mount, runner: arguments.runner, state: context.state)
        return context.run { _ in
            let runner = try await context.resolveRunner(id: runnerID)
            let content = try await runner.handleRead(arguments.path, arguments.offset, arguments.limit)
            return .read(content)
        }
    }
}
