import Foundation
import WuhuAPI

public struct RunnerInfo: Sendable, Hashable {
  public enum Source: String, Sendable, Hashable {
    case builtIn = "built-in"
    case declared
    case incoming
  }

  public var name: String
  public var source: Source
  public var isConnected: Bool

  public init(name: String, source: Source, isConnected: Bool) {
    self.name = name
    self.source = source
    self.isConnected = isConnected
  }
}

public actor RunnerRegistry {
  private let hasBuiltInLocal: Bool
  private var localRunner: (any Runner)?
  private var runners: [String: any Runner] = [:]
  private var declaredNames: Set<String> = []
  private var incomingNames: Set<String> = []

  public init(includeBuiltInLocal: Bool = true) {
    hasBuiltInLocal = includeBuiltInLocal
    if includeBuiltInLocal {
      localRunner = LocalRunner()
    }
  }

  public func declareConfigured(_ names: [String]) {
    for name in names {
      declaredNames.insert(name)
    }
  }

  public func register(_ runner: any Runner) {
    switch runner.id {
    case .local:
      localRunner = runner
    case let .remote(name):
      runners[name] = runner
    }
  }

  @discardableResult
  public func registerIncoming(_ runner: any Runner, name: String) -> Bool {
    if declaredNames.contains(name), runners[name] != nil {
      return false
    }
    if name == "local" {
      localRunner = runner
      return true
    }
    runners[name] = runner
    if !declaredNames.contains(name) {
      incomingNames.insert(name)
    }
    return true
  }

  public func remove(_ id: RunnerID) {
    switch id {
    case .local:
      if hasBuiltInLocal { return }
      localRunner = nil
    case let .remote(name):
      if name == "local" {
        if hasBuiltInLocal { return }
        localRunner = nil
      } else {
        runners.removeValue(forKey: name)
        incomingNames.remove(name)
      }
    }
  }

  public func get(_ id: RunnerID) -> (any Runner)? {
    switch id {
    case .local:
      localRunner
    case let .remote(name):
      name == "local" ? localRunner : runners[name]
    }
  }

  public func get(name: String) -> (any Runner)? {
    if name == "local" { return localRunner }
    return runners[name]
  }

  public func listRunnerNames() -> [String] {
    var names = Set(runners.keys)
    if localRunner != nil {
      names.insert("local")
    }
    return names.sorted()
  }

  public func listAll() -> [RunnerInfo] {
    var result: [RunnerInfo] = []
    result.append(RunnerInfo(name: "local", source: .builtIn, isConnected: localRunner != nil))

    for name in declaredNames.sorted() {
      result.append(RunnerInfo(name: name, source: .declared, isConnected: runners[name] != nil))
    }

    for name in incomingNames.sorted() where runners[name] != nil {
      result.append(RunnerInfo(name: name, source: .incoming, isConnected: true))
    }

    return result
  }

  public func isAvailable(_ id: RunnerID) -> Bool {
    get(id) != nil
  }
}
