import Crypto
import Foundation

/// File-based blob storage for images and other binary data.
///
/// Blobs are stored under `{rootDirectory}/{sessionID}/sha256-{hex}.{ext}`.
/// The blob URI format is `blob://{sessionID}/sha256-{hex}.{ext}`.
/// Content-addressable: duplicate data (same SHA-256) is deduplicated.
public struct WuhuBlobStore: Sendable {
  public let rootDirectory: String

  public init(rootDirectory: String) {
    self.rootDirectory = rootDirectory
  }

  /// Store binary data and return a blob URI.
  ///
  /// - Parameters:
  ///   - sessionID: The session this blob belongs to.
  ///   - data: Raw binary data to store.
  ///   - mimeType: MIME type (e.g. "image/png").
  /// - Returns: A blob URI like `blob://{sessionID}/sha256-{hex}.{ext}`.
  public func store(sessionID: String, data: Data, mimeType: String) throws -> String {
    let hash = SHA256.hash(data: data)
    let hex = hash.map { String(format: "%02x", $0) }.joined()
    let ext = Self.extensionForMimeType(mimeType)
    let filename = "sha256-\(hex).\(ext)"

    let sessionDir = (rootDirectory as NSString).appendingPathComponent(sessionID)
    try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

    let filePath = (sessionDir as NSString).appendingPathComponent(filename)
    if !FileManager.default.fileExists(atPath: filePath) {
      try data.write(to: URL(fileURLWithPath: filePath))
    }

    return "blob://\(sessionID)/\(filename)"
  }

  /// Resolve a blob URI to file data.
  public func resolve(uri: String) throws -> Data {
    let path = try filePath(for: uri)
    return try Data(contentsOf: URL(fileURLWithPath: path))
  }

  /// Resolve a blob URI to a base64-encoded string.
  public func resolveToBase64(uri: String) throws -> String {
    let data = try resolve(uri: uri)
    return data.base64EncodedString()
  }

  /// Get the filesystem path for a blob URI.
  ///
  /// Parses `blob://{sessionID}/{filename}` into a local path.
  public func filePath(for uri: String) throws -> String {
    guard uri.hasPrefix("blob://") else {
      throw BlobStoreError.invalidURI(uri)
    }
    let remainder = String(uri.dropFirst("blob://".count))
    let parts = remainder.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else {
      throw BlobStoreError.invalidURI(uri)
    }
    let sessionID = String(parts[0])
    let filename = String(parts[1])
    return (
      (rootDirectory as NSString)
        .appendingPathComponent(sessionID) as NSString,
    )
    .appendingPathComponent(filename)
  }

  /// Detect MIME type from file extension.
  public static func mimeTypeForExtension(_ ext: String) -> String? {
    switch ext.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    default: nil
    }
  }

  /// Get file extension for a MIME type.
  public static func extensionForMimeType(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": "png"
    case "image/jpeg": "jpg"
    case "image/gif": "gif"
    case "image/webp": "webp"
    default: "bin"
    }
  }

  /// Whether the given file extension is a recognized image format.
  public static func isImageExtension(_ ext: String) -> Bool {
    mimeTypeForExtension(ext) != nil
  }

  /// Maximum supported image file size (10 MB).
  public static let maxImageFileSize = 10 * 1024 * 1024
}

public enum BlobStoreError: Error, CustomStringConvertible {
  case invalidURI(String)
  case fileTooLarge(path: String, size: Int)

  public var description: String {
    switch self {
    case let .invalidURI(uri): "Invalid blob URI: \(uri)"
    case let .fileTooLarge(path, size):
      "Image file too large: \(path) (\(size / 1024 / 1024)MB). Max supported: \(WuhuBlobStore.maxImageFileSize / 1024 / 1024)MB"
    }
  }
}
