import Dependencies
import DependenciesMacros
import Foundation
import WuhuAI

public enum FoundationToolCall: Equatable, Codable, Sendable {
  case read(ReadToolCall)
  case write(WriteToolCall)
  case edit(EditToolCall)
  case ls(LsToolCall)
  case rm(RmToolCall)
  case grep(GrepToolCall)
  case find(FindToolCall)
  case bash(BashToolCall)
  case mount(Mount)
  case park(ParkToolCall)

  public struct ReadToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
    public var offset: Int?
    public var limit: Int?
  }

  public struct WriteToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
    public var content: String
  }

  public struct EditToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
    public var content: String
  }

  public struct LsToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
  }

  public struct RmToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
  }

  public struct GrepToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
    public var pattern: String
  }

  public struct FindToolCall: Equatable, Codable, Sendable {
    public var path: String
    public var mount: String?
    public var runner: String?
    public var pattern: String
  }

  public struct BashToolCall: Equatable, Codable, Sendable {
    public var command: String
    public var mount: String?
    public var runner: String?
  }

  /// A tool that allows LLM to park, until a new message arrives from the system or any user.
  public struct ParkToolCall: Equatable, Codable, Sendable {
    public var reason: String?
    public var timeout: Int?
  }

  public static func parse(_ toolCall: ToolCall) throws -> FoundationToolCall {
    let decoder = JSONValueDecoder()

    switch toolCall.name {
    case "read":
      let read = try decoder.decode(ReadToolCall.self, from: toolCall.arguments)
      return .read(read)
    case "write":
      let write = try decoder.decode(WriteToolCall.self, from: toolCall.arguments)
      return .write(write)
    case "edit":
      let edit = try decoder.decode(EditToolCall.self, from: toolCall.arguments)
      return .edit(edit)
    case "ls":
      let ls = try decoder.decode(LsToolCall.self, from: toolCall.arguments)
      return .ls(ls)
    case "rm":
      let rm = try decoder.decode(RmToolCall.self, from: toolCall.arguments)
      return .rm(rm)
    case "grep":
      let grep = try decoder.decode(GrepToolCall.self, from: toolCall.arguments)
      return .grep(grep)
    case "find":
      let find = try decoder.decode(FindToolCall.self, from: toolCall.arguments)
      return .find(find)
    case "bash":
      let bash = try decoder.decode(BashToolCall.self, from: toolCall.arguments)
      return .bash(bash)
    case "mount":
      let mount = try decoder.decode(Mount.self, from: toolCall.arguments)
      return .mount(mount)
    case "park":
      let park = try decoder.decode(ParkToolCall.self, from: toolCall.arguments)
      return .park(park)
    default:
      throw ParseError.unknownToolCall(toolCall.name)
    }
  }

  public enum ParseError: Error {
    case unknownToolCall(String)
  }
}

public struct FoundationToolResult: Equatable, Codable, Sendable {
  public var toolCallId: String
  public var content: Content
  public var timestamp: Date

  public enum Content: Equatable, Codable, Sendable {
    case read(String)
    case write(String)
    case edit(String)
    case ls(String)
    case rm(String)
    case grep(String)
    case find(String)
    case bash(String)
    case mount(MountResult)
    case park(String)
    case error(String)
  }
}
