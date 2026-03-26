#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import HTTPTypes

public let sharedFetchClient = FetchClient.asyncHTTPClient(HTTPClient.shared)

public func bodyData(_ request: Request) async throws -> Data? {
  guard let body = request.body else { return nil }
  return try await body.data()
}

public func headerValues(_ headers: Headers, named name: String) -> [String] {
  guard let fieldName = HTTPField.Name(name) else { return [] }
  return headers.compactMap { field in
    field.name == fieldName ? field.value : nil
  }
}

public extension Request {
  init(
    url: URL,
    method: String = "GET",
    headers: [String: [String]] = [:],
    body: Data? = nil,
  ) {
    var requestHeaders = Headers()
    for (name, values) in headers {
      guard let fieldName = HTTPField.Name(name) else { continue }
      for value in values {
        requestHeaders[fieldName] = value
      }
    }

    self.init(
      url: url,
      method: Method(rawValue: method) ?? .get,
      headers: requestHeaders,
      body: body.map { .bytes(Array($0)) },
    )
  }

  mutating func setHeader(_ value: String, for name: String) {
    guard let fieldName = HTTPField.Name(name) else { return }
    headers[fieldName] = value
  }

  mutating func addHeader(_ value: String, for name: String) {
    setHeader(value, for: name)
  }

  mutating func setBody(_ data: Data, contentType: String? = nil) {
    body = .bytes(Array(data), contentType: contentType)
  }
}
