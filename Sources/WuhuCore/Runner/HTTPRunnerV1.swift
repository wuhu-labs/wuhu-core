import Foundation

public enum HTTPRunnerV1 {
  public enum ErrorCode: String, Sendable, Hashable, Codable {
    case invalidRequest = "invalid_request"
    case missingBasePath = "missing_base_path"
    case invalidBasePath = "invalid_base_path"
    case fileNotFound = "file_not_found"
    case notADirectory = "not_a_directory"
    case offsetOutOfRange = "offset_out_of_range"
    case editConflict = "edit_conflict"
    case unsupportedOperation = "unsupported_operation"
    case internalError = "internal_error"
  }

  public struct ErrorPayload: Sendable, Hashable, Codable {
    public var code: ErrorCode
    public var message: String

    public init(code: ErrorCode, message: String) {
      self.code = code
      self.message = message
    }
  }

  public struct ErrorResponse: Sendable, Hashable, Codable {
    public var error: ErrorPayload

    public init(error: ErrorPayload) {
      self.error = error
    }
  }

  public struct ReadRequest: Sendable, Hashable, Codable {
    public var path: String
    public var basePath: String?
    public var offset: Int?
    public var limit: Int?

    public init(
      path: String,
      basePath: String? = nil,
      offset: Int? = nil,
      limit: Int? = nil,
    ) {
      self.path = path
      self.basePath = basePath
      self.offset = offset
      self.limit = limit
    }
  }

  public struct ReadResponse: Sendable, Hashable, Codable {
    public var resolvedPath: String
    public var content: String
    public var totalLines: Int
    public var startLine: Int
    public var endLine: Int
    public var hasMore: Bool
    public var nextOffset: Int?

    public init(
      resolvedPath: String,
      content: String,
      totalLines: Int,
      startLine: Int,
      endLine: Int,
      hasMore: Bool,
      nextOffset: Int?,
    ) {
      self.resolvedPath = resolvedPath
      self.content = content
      self.totalLines = totalLines
      self.startLine = startLine
      self.endLine = endLine
      self.hasMore = hasMore
      self.nextOffset = nextOffset
    }
  }

  public struct WriteRequest: Sendable, Hashable, Codable {
    public var path: String
    public var basePath: String?
    public var content: String
    public var createDirectories: Bool

    public init(
      path: String,
      basePath: String? = nil,
      content: String,
      createDirectories: Bool = true,
    ) {
      self.path = path
      self.basePath = basePath
      self.content = content
      self.createDirectories = createDirectories
    }
  }

  public struct WriteResponse: Sendable, Hashable, Codable {
    public var resolvedPath: String
    public var bytesWritten: Int

    public init(resolvedPath: String, bytesWritten: Int) {
      self.resolvedPath = resolvedPath
      self.bytesWritten = bytesWritten
    }
  }

  public struct LsRequest: Sendable, Hashable, Codable {
    public var path: String?
    public var basePath: String?
    public var limit: Int?

    public init(
      path: String? = nil,
      basePath: String? = nil,
      limit: Int? = nil,
    ) {
      self.path = path
      self.basePath = basePath
      self.limit = limit
    }
  }

  public struct LsResponse: Sendable, Hashable, Codable {
    public var resolvedPath: String
    public var entries: [DirectoryEntry]
    public var totalEntries: Int
    public var returnedEntries: Int
    public var hasMore: Bool

    public init(
      resolvedPath: String,
      entries: [DirectoryEntry],
      totalEntries: Int,
      returnedEntries: Int,
      hasMore: Bool,
    ) {
      self.resolvedPath = resolvedPath
      self.entries = entries
      self.totalEntries = totalEntries
      self.returnedEntries = returnedEntries
      self.hasMore = hasMore
    }
  }

  public struct EditRequest: Sendable, Hashable, Codable {
    public var path: String
    public var basePath: String?
    public var oldText: String
    public var newText: String

    public init(
      path: String,
      basePath: String? = nil,
      oldText: String,
      newText: String,
    ) {
      self.path = path
      self.basePath = basePath
      self.oldText = oldText
      self.newText = newText
    }
  }

  public struct EditResponse: Sendable, Hashable, Codable {
    public var resolvedPath: String
    public var firstChangedLine: Int
    public var diff: String

    public init(
      resolvedPath: String,
      firstChangedLine: Int,
      diff: String,
    ) {
      self.resolvedPath = resolvedPath
      self.firstChangedLine = firstChangedLine
      self.diff = diff
    }
  }

  public struct BashStartRequest: Sendable, Hashable, Codable {
    public var taskID: String
    public var command: String
    public var cwd: String
    public var timeout: Double?

    public init(
      taskID: String,
      command: String,
      cwd: String,
      timeout: Double? = nil,
    ) {
      self.taskID = taskID
      self.command = command
      self.cwd = cwd
      self.timeout = timeout
    }
  }

  public struct BashStartResponse: Sendable, Hashable, Codable {
    public init() {}
  }

  public struct BashStreamRequest: Sendable, Hashable, Codable {
    public var taskID: String
    public var after: BashStreamCursor?

    public init(taskID: String, after: BashStreamCursor? = nil) {
      self.taskID = taskID
      self.after = after
    }
  }

  public struct BashAckRequest: Sendable, Hashable, Codable {
    public var taskID: String
    public var through: BashStreamCursor

    public init(taskID: String, through: BashStreamCursor) {
      self.taskID = taskID
      self.through = through
    }
  }

  public struct BashAckResponse: Sendable, Hashable, Codable {
    public init() {}
  }

  public struct BashKillRequest: Sendable, Hashable, Codable {
    public var taskID: String

    public init(taskID: String) {
      self.taskID = taskID
    }
  }

  public struct BashKillResponse: Sendable, Hashable, Codable {
    public init() {}
  }
}
