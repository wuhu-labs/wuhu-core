import Dependencies
import DependenciesMacros
import WuhuAI

public enum SessionToolCall: Equatable, Codable, Sendable {
  case read(ReadToolCall)
  case write(WriteToolCall)
  case find(FindToolCall)
  case bash(BashToolCall)
  case setTitle(SetTitleToolCall)
  case mount(Mount)

  public struct ReadToolCall: Equatable, Codable, Sendable {

  }

  public struct WriteToolCall: Equatable, Codable, Sendable {

  }

  public struct FindToolCall: Equatable, Codable, Sendable {


  }

  public struct BashToolCall: Equatable, Codable, Sendable {

  }

  public struct SetTitleToolCall: Equatable, Codable, Sendable {
    public var title: String
  }

  public static func parse(_ toolCall: ToolCall) throws -> SessionToolCall {
    fatalError("Not implemented")
  }
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
      return "local"
    case .remote(name: let name):
      return "remote:\(name)"
    }
  }
}

public struct Mount: Codable, Hashable, Sendable {
  public var name: String
  public var runner: RunnerID
  public var path: String
}

@DependencyClient
public struct Runner: Sendable {
  public var readTextFile: @Sendable (_ path: String) async throws -> String
  public var listDirectory: @Sendable (_ path: String) async throws -> [String]
}
