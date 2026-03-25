import Fetch
import Foundation
import Serve
import ServeNIO
import ServeRouting
import WuhuCore

public struct WuhuHTTPRunnerServer: Sendable {
  public init() {}

  public static func handler(
    runner: any Runner,
    name _: String = "local"
  ) -> Handler {
    var router = Router()

    router.get("/healthz") { _, _ in
      Response(status: .ok, body: .string("ok"))
    }

    router.post("/v1/fs/read") { request, _ in
      await respond {
        let payload = try await decodeJSONBody(HTTPRunnerV1.ReadRequest.self, from: request)
        let resolvedPath = try resolveAbsolutePath(path: payload.path, basePath: payload.basePath)

        if let offset = payload.offset, offset < 1 {
          throw routeError(
            status: .badRequest,
            code: .invalidRequest,
            message: "offset must be >= 1"
          )
        }
        if let limit = payload.limit, limit < 1 {
          throw routeError(
            status: .badRequest,
            code: .invalidRequest,
            message: "limit must be >= 1"
          )
        }

        let raw = try await runner.readString(path: resolvedPath, encoding: .utf8)
        let normalized = normalizeToLF(raw)
        let allLines = normalized.isEmpty
          ? []
          : normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let requestedOffset = payload.offset ?? 1

        if allLines.isEmpty {
          if requestedOffset > 1 {
            throw routeError(
              status: .unprocessableContent,
              code: .offsetOutOfRange,
              message: "Offset \(requestedOffset) is beyond end of file (0 lines total)"
            )
          }

          return jsonResponse(
            HTTPRunnerV1.ReadResponse(
              resolvedPath: resolvedPath,
              content: "",
              totalLines: 0,
              startLine: 0,
              endLine: 0,
              hasMore: false,
              nextOffset: nil
            )
          )
        }

        let startIndex = requestedOffset - 1
        guard startIndex < allLines.count else {
          throw routeError(
            status: .unprocessableContent,
            code: .offsetOutOfRange,
            message: "Offset \(requestedOffset) is beyond end of file (\(allLines.count) lines total)"
          )
        }

        let endIndex = if let limit = payload.limit {
          min(startIndex + limit, allLines.count)
        } else {
          allLines.count
        }

        let selected = Array(allLines[startIndex ..< endIndex])
        let hasMore = endIndex < allLines.count

        return jsonResponse(
          HTTPRunnerV1.ReadResponse(
            resolvedPath: resolvedPath,
            content: selected.joined(separator: "\n"),
            totalLines: allLines.count,
            startLine: requestedOffset,
            endLine: endIndex,
            hasMore: hasMore,
            nextOffset: hasMore ? (endIndex + 1) : nil
          )
        )
      }
    }

    router.post("/v1/fs/write") { request, _ in
      await respond {
        let payload = try await decodeJSONBody(HTTPRunnerV1.WriteRequest.self, from: request)
        let resolvedPath = try resolveAbsolutePath(path: payload.path, basePath: payload.basePath)

        try await runner.writeString(
          path: resolvedPath,
          content: payload.content,
          createIntermediateDirectories: payload.createDirectories,
          encoding: .utf8
        )

        return jsonResponse(
          HTTPRunnerV1.WriteResponse(
            resolvedPath: resolvedPath,
            bytesWritten: payload.content.utf8.count
          )
        )
      }
    }

    router.post("/v1/fs/ls") { request, _ in
      await respond {
        let payload = try await decodeJSONBody(HTTPRunnerV1.LsRequest.self, from: request)
        let resolvedPath = try resolveAbsolutePath(
          path: payload.path ?? ".",
          basePath: payload.basePath
        )

        if let limit = payload.limit, limit < 1 {
          throw routeError(
            status: .badRequest,
            code: .invalidRequest,
            message: "limit must be >= 1"
          )
        }

        let entries = try await runner.listDirectory(path: resolvedPath)
          .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
          }

        let returnedEntries: [DirectoryEntry] = if let limit = payload.limit {
          Array(entries.prefix(limit))
        } else {
          entries
        }

        return jsonResponse(
          HTTPRunnerV1.LsResponse(
            resolvedPath: resolvedPath,
            entries: returnedEntries,
            totalEntries: entries.count,
            returnedEntries: returnedEntries.count,
            hasMore: returnedEntries.count < entries.count
          )
        )
      }
    }

    router.post("/v1/fs/edit") { request, _ in
      await respond {
        let payload = try await decodeJSONBody(HTTPRunnerV1.EditRequest.self, from: request)
        let resolvedPath = try resolveAbsolutePath(path: payload.path, basePath: payload.basePath)

        let rawData = try await runner.readData(path: resolvedPath)
        let raw = String(decoding: rawData, as: UTF8.self)
        let (bom, contentWithoutBom) = stripBom(raw)
        let originalEnding = detectLineEnding(contentWithoutBom)

        let normalizedContent = normalizeToLF(contentWithoutBom)
        let normalizedOldText = normalizeToLF(payload.oldText)
        let normalizedNewText = normalizeToLF(payload.newText)

        let match = fuzzyFindText(content: normalizedContent, needle: normalizedOldText)
        guard match.found else {
          throw routeError(
            status: .conflict,
            code: .editConflict,
            message: "Could not find the exact text in \(payload.path). The old text must match exactly including all whitespace and newlines."
          )
        }

        let fuzzyContent = normalizeForFuzzyMatch(normalizedContent)
        let fuzzyNeedle = normalizeForFuzzyMatch(normalizedOldText)
        let occurrences = fuzzyContent.components(separatedBy: fuzzyNeedle).count - 1
        if occurrences > 1 {
          throw routeError(
            status: .conflict,
            code: .editConflict,
            message: "Found \(occurrences) occurrences of the text in \(payload.path). The text must be unique. Please provide more context to make it unique."
          )
        }

        let baseContent = match.contentForReplacement
        let updatedContent = baseContent.replacingCharacters(in: match.range, with: normalizedNewText)

        if baseContent == updatedContent {
          throw routeError(
            status: .conflict,
            code: .editConflict,
            message: "No changes made to \(payload.path). The replacement produced identical content."
          )
        }

        let firstChangedLine = 1 + baseContent[..<match.range.lowerBound]
          .split(separator: "\n", omittingEmptySubsequences: false)
          .count - 1

        let final = bom + restoreLineEndings(updatedContent, ending: originalEnding)
        try await runner.writeString(
          path: resolvedPath,
          content: final,
          createIntermediateDirectories: false,
          encoding: .utf8
        )

        return jsonResponse(
          HTTPRunnerV1.EditResponse(
            resolvedPath: resolvedPath,
            firstChangedLine: firstChangedLine,
            diff: formatSimpleDiff(
              oldText: normalizedOldText,
              newText: normalizedNewText,
              line: firstChangedLine
            )
          )
        )
      }
    }

    return router.handler
  }

  public static func listen(
    host: String = "127.0.0.1",
    port: Int,
    runner: any Runner = LocalRunner(),
    name: String = "local",
    options: ServeOptions = .init()
  ) async throws -> ServeNIOListener {
    try await ServeNIOListener.bind(
      host: host,
      port: port,
      options: options,
      handler: self.handler(runner: runner, name: name)
    )
  }

  public func run(configPath: String?) async throws {
    let path = (configPath?.isEmpty == false) ? configPath! : WuhuRunnerConfig.defaultPath()
    let config = try WuhuRunnerConfig.load(path: path)
    try await self.run(config: config)
  }

  public func run(config: WuhuRunnerConfig) async throws {
    let host = config.listen?.host ?? "0.0.0.0"
    let port = config.listen?.port ?? 5532
    let listener = try await Self.listen(
      host: host,
      port: port,
      runner: LocalRunner(),
      name: config.name
    )

    writeStderr("Starting HTTP runner '\(config.name)' on \(host):\(port)\n")

    do {
      while true {
        try await Task.sleep(for: .seconds(86_400))
      }
    } catch is CancellationError {
      await listener.close()
    }
  }
}

private struct HTTPRunnerRouteError: Error, Sendable {
  var status: Status
  var code: HTTPRunnerV1.ErrorCode
  var message: String
}

private func routeError(
  status: Status,
  code: HTTPRunnerV1.ErrorCode,
  message: String
) -> HTTPRunnerRouteError {
  HTTPRunnerRouteError(status: status, code: code, message: message)
}

private func respond(
  _ operation: @escaping @Sendable () async throws -> Response
) async -> Response {
  do {
    return try await operation()
  } catch let error as HTTPRunnerRouteError {
    return jsonErrorResponse(error)
  } catch let error as RunnerError {
    return jsonErrorResponse(mapRunnerError(error))
  } catch {
    return jsonErrorResponse(
      routeError(
        status: .internalServerError,
        code: .internalError,
        message: String(describing: error)
      )
    )
  }
}

private func mapRunnerError(_ error: RunnerError) -> HTTPRunnerRouteError {
  switch error {
  case let .fileNotFound(path):
    routeError(
      status: .notFound,
      code: .fileNotFound,
      message: "File not found: \(path)"
    )
  case let .notADirectory(path):
    routeError(
      status: .unprocessableContent,
      code: .notADirectory,
      message: "Not a directory: \(path)"
    )
  case let .requestFailed(message):
    routeError(
      status: .internalServerError,
      code: .internalError,
      message: message
    )
  case let .timeout(message):
    routeError(
      status: Status(code: 504, reasonPhrase: "Gateway Timeout"),
      code: .internalError,
      message: message
    )
  case let .disconnected(runnerName):
    routeError(
      status: .internalServerError,
      code: .internalError,
      message: "Runner '\(runnerName)' is disconnected"
    )
  }
}

private func decodeJSONBody<Payload: Decodable>(
  _ type: Payload.Type,
  from request: Request
) async throws -> Payload {
  guard let body = request.body else {
    throw routeError(
      status: .badRequest,
      code: .invalidRequest,
      message: "Missing JSON request body"
    )
  }

  do {
    return try await body.json(type, decoder: WuhuJSON.decoder)
  } catch {
    throw routeError(
      status: .badRequest,
      code: .invalidRequest,
      message: "Invalid JSON request body: \(error)"
    )
  }
}

private func resolveAbsolutePath(
  path rawPath: String,
  basePath rawBasePath: String?
) throws -> String {
  let expandedPath = ToolPath.expand(rawPath)
  if expandedPath.hasPrefix("/") {
    return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
  }

  guard let rawBasePath else {
    throw routeError(
      status: .badRequest,
      code: .missingBasePath,
      message: "basePath is required when path is relative"
    )
  }

  let expandedBasePath = ToolPath.expand(rawBasePath)
  guard expandedBasePath.hasPrefix("/") else {
    throw routeError(
      status: .badRequest,
      code: .invalidBasePath,
      message: "basePath must be absolute"
    )
  }

  let normalizedBasePath = URL(fileURLWithPath: expandedBasePath).standardizedFileURL.path
  return ToolPath.resolveToCwd(expandedPath, cwd: normalizedBasePath)
}

private func jsonResponse(
  _ value: some Encodable,
  status: Status = .ok
) -> Response {
  do {
    let body = try Body.json(value, encoder: WuhuJSON.encoder)
    var headers = Headers()
    if let contentType = body.contentType {
      headers[.contentType] = contentType
    }
    if let contentLength = body.contentLength {
      headers[.contentLength] = String(contentLength)
    }
    return Response(status: status, headers: headers, body: body)
  } catch {
    return jsonErrorResponse(
      routeError(
        status: .internalServerError,
        code: .internalError,
        message: String(describing: error)
      )
    )
  }
}

private func jsonErrorResponse(_ error: HTTPRunnerRouteError) -> Response {
  jsonResponse(
    HTTPRunnerV1.ErrorResponse(
      error: .init(code: error.code, message: error.message)
    ),
    status: error.status
  )
}

private func writeStderr(_ text: String) {
  FileHandle.standardError.write(Data(text.utf8))
}

private func stripBom(_ content: String) -> (bom: String, text: String) {
  if content.hasPrefix("\u{FEFF}") {
    return ("\u{FEFF}", String(content.dropFirst()))
  }
  return ("", content)
}

private func detectLineEnding(_ content: String) -> String {
  content.contains("\r\n") ? "\r\n" : "\n"
}

private func normalizeToLF(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n")
}

private func restoreLineEndings(_ text: String, ending: String) -> String {
  ending == "\r\n"
    ? text.replacingOccurrences(of: "\n", with: "\r\n")
    : text
}

private func normalizeForFuzzyMatch(_ text: String) -> String {
  let stripped = text
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { trimEnd(String($0)) }
    .joined(separator: "\n")

  return stripped
    .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201A}\u{201B}]", with: "'", options: .regularExpression)
    .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201E}\u{201F}]", with: "\"", options: .regularExpression)
    .replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}]", with: "-", options: .regularExpression)
    .replacingOccurrences(of: "[\u{00A0}\u{2002}-\u{200A}\u{202F}\u{205F}\u{3000}]", with: " ", options: .regularExpression)
}

private func trimEnd(_ text: String) -> String {
  var end = text.endIndex
  while end > text.startIndex {
    let before = text.index(before: end)
    let character = text[before]
    if character == " " || character == "\t" {
      end = before
      continue
    }
    break
  }
  return String(text[..<end])
}

private struct FuzzyMatch: Sendable {
  var found: Bool
  var range: Range<String.Index>
  var contentForReplacement: String
}

private func fuzzyFindText(content: String, needle: String) -> FuzzyMatch {
  if let range = content.range(of: needle) {
    return .init(found: true, range: range, contentForReplacement: content)
  }

  let fuzzyContent = normalizeForFuzzyMatch(content)
  let fuzzyNeedle = normalizeForFuzzyMatch(needle)
  if let range = fuzzyContent.range(of: fuzzyNeedle) {
    return .init(found: true, range: range, contentForReplacement: fuzzyContent)
  }

  return .init(
    found: false,
    range: content.startIndex ..< content.startIndex,
    contentForReplacement: content
  )
}

private func formatSimpleDiff(oldText: String, newText: String, line: Int) -> String {
  let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false)
  let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)

  var output: [String] = []
  output.append("@@ line \(line) @@")
  for line in oldLines {
    output.append("-\(line)")
  }
  for line in newLines {
    output.append("+\(line)")
  }
  return output.joined(separator: "\n")
}
