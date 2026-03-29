import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct FoundationExecutor: Sendable {
  public var handleGenericRead: @Sendable (_ url: URL, _ offset: Int?, _ limit: Int?) async throws -> ReadTool.Result
  public var handleGenericWrite: @Sendable (_ url: URL, _ content: String) async throws -> WriteTool.Result
  public var resolveRunner: @Sendable (_ id: RunnerID) async throws -> Runner
}

extension FoundationExecutor: TestDependencyKey {
  public static let testValue: FoundationExecutor = .init()
}

@DependencyClient
public struct Runner: Sendable {
  public var handleRead: @Sendable (_ path: String, _ offset: Int?, _ limit: Int?) async throws -> ReadTool.Result
  public var handleWrite: @Sendable (_ path: String, _ content: String) async throws -> WriteTool.Result
  public var handleEdit: @Sendable (_ path: String, _ content: String) async throws -> EditTool.Result
  public var handleLs: @Sendable (_ path: String) async throws -> LsTool.Result
  public var handleRm: @Sendable (_ path: String) async throws -> RmTool.Result
  public var handleGrep: @Sendable (_ path: String, _ pattern: String) async throws -> GrepTool.Result
  public var handleFind: @Sendable (_ path: String, _ pattern: String) async throws -> FindTool.Result
  public var handleBash: @Sendable (_ command: String) async throws -> BashTool.Result
  public var handleMount: @Sendable (_ mount: Mount) async throws -> MountTool.Result
}

public enum RunnerID: Sendable, RawRepresentable, Hashable, Codable {
  case local
  case remote(name: String)

  public init?(rawValue: String) {
    if rawValue == "local" {
      self = .local
      return
    }

    if rawValue.starts(with: "remote:") {
      let name = rawValue.dropFirst(7)
      if name.isEmpty {
        return nil
      }
      if name.utf8.count >= 64 {
        return nil
      }
      let allValid = name.allSatisfy {
        guard $0.isASCII else {
          return false
        }
        if $0.isLetter || $0.isNumber {
          return true
        }
        return "-_".contains($0)
      }
      if !allValid {
        return nil
      }
      self = .remote(name: String(name))
      return
    }

    return nil
  }

  public var rawValue: String {
    switch self {
    case .local:
      "local"
    case let .remote(name: name):
      "remote:\(name)"
    }
  }
}
