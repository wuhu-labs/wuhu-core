import DependenciesMacros

public struct Mount: Codable, Hashable, Sendable {
  public var name: String
  public var runner: RunnerID
  public var path: String
}

public struct MountResult: Codable, Sendable, Equatable {
  public var mount: Mount
  public var agentsMD: String?
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

@DependencyClient
public struct Runner: Sendable {
  public var readTextFile: @Sendable (_ path: String) async throws -> String
  public var listDirectory: @Sendable (_ path: String) async throws -> [String]

  public var handleRead: @Sendable (_ path: String, _ offset: Int?, _ limit: Int?) async throws -> String
  public var handleWrite: @Sendable (_ path: String, _ content: String) async throws -> Void
  public var handleEdit: @Sendable (_ path: String, _ content: String) async throws -> Void
  public var handleLs: @Sendable (_ path: String) async throws -> [String]
  public var handleRm: @Sendable (_ path: String) async throws -> Void
  public var handleGrep: @Sendable (_ path: String, _ pattern: String) async throws -> [String]
  public var handleFind: @Sendable (_ path: String, _ pattern: String) async throws -> [String]
  public var handleBash: @Sendable (_ command: String) async throws -> Void
}
