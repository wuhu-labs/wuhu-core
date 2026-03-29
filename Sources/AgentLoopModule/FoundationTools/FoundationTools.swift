import Dependencies
import WuhuAI

public struct FoundationTools: Sendable {
  public struct State: Equatable, Sendable {
    public var mounts: [Mount] = []
  }

  public enum Action: Sendable {
    case mount(MountResult)
    case toolCallDidFinish(FoundationToolResult)

    public static func toolError(_ id: String, _ message: String) -> Action {
      @Dependency(\.date)
      var date

      return .toolCallDidFinish(.init(toolCallId: id, content: .error(message), timestamp: date()))
    }
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
    _ toolCall: FoundationToolCall,
    toolCallId: String,
    state: State,
  ) -> DeferredExecution<Action> {
    do {
      switch toolCall {
      case let .read(readToolCall):
        return try handleRead(toolCallId: toolCallId, readToolCall: readToolCall, state: state)
      case let .write(writeToolCall):
        return try handleWrite(toolCallId: toolCallId, writeToolCall: writeToolCall, state: state)
      case let .edit(editToolCall):
        return try handleEdit(toolCallId: toolCallId, editToolCall: editToolCall, state: state)
      case let .ls(lsToolCall):
        return try handleLs(toolCallId: toolCallId, lsToolCall: lsToolCall, state: state)
      case let .rm(rmToolCall):
        return try handleRm(toolCallId: toolCallId, rmToolCall: rmToolCall, state: state)
      case let .grep(grepToolCall):
        return try handleGrep(toolCallId: toolCallId, grepToolCall: grepToolCall, state: state)
      case let .find(findToolCall):
        return try handleFind(toolCallId: toolCallId, findToolCall: findToolCall, state: state)
      case let .bash(bashToolCall):
        return try handleBash(toolCallId: toolCallId, bashToolCall: bashToolCall, state: state)
      case let .mount(mount):
        return try handleMount(toolCallId: toolCallId, mount: mount, state: state)
      case let .park(parkToolCall):
        return try handlePark(toolCallId: toolCallId, parkToolCall: parkToolCall, state: state)
      }
    } catch {
      let toolResult = FoundationToolResult(toolCallId: toolCallId, content: .error(String(describing: error)), timestamp: date())
      return .send(.toolCallDidFinish(toolResult))
    }
  }

  func handleRead(
    toolCallId: String,
    readToolCall: FoundationToolCall.ReadToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: readToolCall.mount, runner: readToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      let content = try await runner.handleRead(readToolCall.path, readToolCall.offset, readToolCall.limit)
      return .read(content)
    }
  }

  func handleWrite(
    toolCallId: String,
    writeToolCall: FoundationToolCall.WriteToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: writeToolCall.mount, runner: writeToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleWrite(writeToolCall.path, writeToolCall.content)
      return .write(writeToolCall.content)
    }
  }

  func handleEdit(
    toolCallId: String,
    editToolCall: FoundationToolCall.EditToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: editToolCall.mount, runner: editToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleEdit(editToolCall.path, editToolCall.content)
      return .edit(editToolCall.content)
    }
  }

  func handleLs(
    toolCallId: String,
    lsToolCall: FoundationToolCall.LsToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: lsToolCall.mount, runner: lsToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleLs(lsToolCall.path)
      return .ls(files.joined(separator: "\n"))
    }
  }

  func handleRm(
    toolCallId: String,
    rmToolCall: FoundationToolCall.RmToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: rmToolCall.mount, runner: rmToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleRm(rmToolCall.path)
      return .rm(rmToolCall.path)
    }
  }

  func handleGrep(
    toolCallId: String,
    grepToolCall: FoundationToolCall.GrepToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: grepToolCall.mount, runner: grepToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleGrep(grepToolCall.path, grepToolCall.pattern)
      return .grep(files.joined(separator: "\n"))
    }
  }

  func handleFind(
    toolCallId: String,
    findToolCall: FoundationToolCall.FindToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: findToolCall.mount, runner: findToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      let files = try await runner.handleFind(findToolCall.path, findToolCall.pattern)
      return .find(files.joined(separator: "\n"))
    }
  }

  func handleBash(
    toolCallId: String,
    bashToolCall: FoundationToolCall.BashToolCall,
    state: State,
  ) throws -> DeferredExecution<Action> {
    let runnerID = try resolveRunnerID(mount: bashToolCall.mount, runner: bashToolCall.runner, state: state)
    return run(toolCallId: toolCallId) { _ in
      let runner = try await resolveRunner(id: runnerID)
      try await runner.handleBash(bashToolCall.command)
      return .bash(bashToolCall.command)
    }
  }

  func handleMount(toolCallId: String, mount: Mount, state: State) throws -> DeferredExecution<Action> {
    let noDuplicates = state.mounts.allSatisfy {
      $0.name != mount.name
    }
    guard noDuplicates else {
      throw ValidationError.duplicatedMountName(mount.name)
    }

    return run(toolCallId: toolCallId) { send in
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

  func handlePark(
    toolCallId _: String,
    parkToolCall _: FoundationToolCall.ParkToolCall,
    state _: State,
  ) throws -> DeferredExecution<Action> {
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
    toolCallId: String,
    body: @escaping @Sendable (
      _ send: @Sendable (Action) -> Void,
    ) async throws -> FoundationToolResult.Content,
  ) -> DeferredExecution<Action> {
    DeferredExecution { coordinator in
      do {
        let content = try await body(coordinator.send)
        let toolResult = FoundationToolResult(toolCallId: toolCallId, content: content, timestamp: date())
        coordinator.send(.toolCallDidFinish(toolResult))
      } catch {
        let toolResult = FoundationToolResult(toolCallId: toolCallId, content: .error(String(describing: error)), timestamp: date())
        coordinator.send(.toolCallDidFinish(toolResult))
      }
    }
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
