import Dependencies
import WuhuAI

public struct FoundationTools: Sendable {
  public init() {}

  public struct State: Equatable, Sendable {
    public var mounts: [Mount] = []

    public init() {}
  }

  public enum Action: Sendable {
    case mount(MountResult)
    case toolCallDidFinish(FoundationToolResult)
  }

  @Dependency(\.date)
  private var date

  public func reduce(action: Action, state: inout State) {
    switch action {
    case let .mount(mountResult):
      state.mounts.append(mountResult.mount)
    default:
      return
    }
  }

  public func startToolCall(
    _ untypedToolCall: ToolCall,
    state: State,
  ) -> DeferredExecution<Action> {
    let executor = ToolCallExecutor(untypedToolCall: untypedToolCall)
    return executor.process(state: state)
  }

  public enum ValidationError: Error, Sendable {
    case duplicatedMountName(String)
    case mountNotFound(String)
    case invalidRunnerID(String)
  }

  public enum ExecutionError: Error, Sendable {
    case runnerNotFound(RunnerID)
  }
}

struct ToolCallExecutor {
  var untypedToolCall: ToolCall

  typealias ValidationError = FoundationTools.ValidationError
  typealias ExecutionError = FoundationTools.ExecutionError
  typealias State = FoundationTools.State
  typealias Action = FoundationTools.Action

  @Dependency(\.date)
  var date

  func makeToolCallResult(content: FoundationToolResult.Content) -> FoundationToolResult {
    .init(toolCallId: untypedToolCall.id, toolName: untypedToolCall.name, content: content, timestamp: date())
  }

  func process(state: State) -> DeferredExecution<Action> {
    do {
      let toolCall = try FoundationToolCall.parse(untypedToolCall)

      switch toolCall {
      case let .read(readToolCall):
        return try handle(read: readToolCall, state: state)
      case let .write(writeToolCall):
        return try handle(write: writeToolCall, state: state)
      case let .edit(editToolCall):
        return try handle(edit: editToolCall, state: state)
      case let .ls(lsToolCall):
        return try handle(ls: lsToolCall, state: state)
      case let .rm(rmToolCall):
        return try handle(rm: rmToolCall, state: state)
      case let .grep(grepToolCall):
        return try handle(grep: grepToolCall, state: state)
      case let .find(findToolCall):
        return try handle(find: findToolCall, state: state)
      case let .bash(bashToolCall):
        return try handle(bash: bashToolCall, state: state)
      case let .mount(mount):
        return try handle(mount: mount, state: state)
      case let .park(parkToolCall):
        return try handle(park: parkToolCall, state: state)
      }
    } catch {
      return .send(.toolCallDidFinish(makeToolCallResult(content: .error(String(describing: error)))))
    }
  }

  func handle(read: FoundationToolCall.ReadToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: read.mount, runner: read.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      let content = try await runner.handleRead(read.path, read.offset, read.limit)
      return .read(content)
    }
  }

  func handle(write: FoundationToolCall.WriteToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: write.mount, runner: write.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleWrite(write.path, write.content)
      return .write(write.content)
    }
  }

  func handle(edit: FoundationToolCall.EditToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: edit.mount, runner: edit.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleEdit(edit.path, edit.content)
      return .edit(edit.content)
    }
  }

  func handle(ls: FoundationToolCall.LsToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: ls.mount, runner: ls.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleLs(ls.path)
      return .ls(files.joined(separator: "\n"))
    }
  }

  func handle(rm: FoundationToolCall.RmToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: rm.mount, runner: rm.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleRm(rm.path)
      return .rm(rm.path)
    }
  }

  func handle(grep: FoundationToolCall.GrepToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: grep.mount, runner: grep.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleGrep(grep.path, grep.pattern)
      return .grep(files.joined(separator: "\n"))
    }
  }

  func handle(find: FoundationToolCall.FindToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: find.mount, runner: find.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleFind(find.path, find.pattern)
      return .find(files.joined(separator: "\n"))
    }
  }

  func handle(bash: FoundationToolCall.BashToolCall, state: State) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: bash.mount, runner: bash.runner, state: state)
    return run { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleBash(bash.command)
      return .bash(bash.command)
    }
  }

  func handle(mount: Mount, state: State) throws -> DeferredExecution<Action> {
    let noDuplicates = state.mounts.allSatisfy {
      $0.name != mount.name
    }
    guard noDuplicates else {
      throw ValidationError.duplicatedMountName(mount.name)
    }

    return run { send in
      let runner = try await resolveRunner(id: mount.runner)
      let files = try await runner.listDirectory(path: mount.path)
      var agentsMD: String?
      if files.contains("AGENTS.md") {
        agentsMD = try await runner.readTextFile(path: mount.path + "/" + "AGENTS.md")
      }

      let mountResult = MountResult(mount: mount, agentsMD: agentsMD)

      send(.mount(mountResult))
      return .mount(mountResult)
    }
  }

  func handle(park _: FoundationToolCall.ParkToolCall, state _: State) throws -> DeferredExecution<Action> {
    fatalError()
  }

  func resolveRunnerID(mount: String?, runner: String?, state: State) throws -> RunnerID {
    if let providedMount = mount {
      let mount = state.mounts.first { $0.name == providedMount }
      guard let mount else {
        throw ValidationError.mountNotFound(providedMount)
      }
      return mount.runner
    } else if let providedRunner = runner {
      guard let parsedRunner = RunnerID(rawValue: providedRunner) else {
        throw ValidationError.invalidRunnerID(providedRunner)
      }
      return parsedRunner
    } else {
      return .local
    }
  }

  func resolveRunner(id runnerID: RunnerID) async throws -> Runner {
    throw ExecutionError.runnerNotFound(runnerID)
  }

  func run(
    body: @escaping @Sendable (
      _ send: @Sendable (Action) -> Void,
    ) async throws -> FoundationToolResult.Content,
  ) -> DeferredExecution<Action> {
    DeferredExecution { coordinator in
      do {
        let content = try await body(coordinator.send)
        coordinator.send(.toolCallDidFinish(makeToolCallResult(content: content)))
      } catch {
        coordinator.send(.toolCallDidFinish(makeToolCallResult(content: .error(String(describing: error)))))
      }
    }
  }
}
