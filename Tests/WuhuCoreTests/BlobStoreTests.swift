import Dependencies
import Foundation
import Testing
@testable import WuhuCore

struct BlobBucketTests {
  private func makeTempDir() throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wuhu-blob-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
  }

  @Test func storeAndResolveRoundTrip() async throws {
    let root = try makeTempDir()
    try await withDependencies {
      $0.dataBucket = LocalDataBucket(rootDirectory: root)
    } operation: {
      let data = Data("hello image".utf8)
      let uri = try await BlobBucket.store(namespace: "sess-1", data: data, mimeType: "image/png")

      #expect(uri.hasPrefix("blob://sess-1/sha256-"))
      #expect(uri.hasSuffix(".png"))

      let resolved = try await BlobBucket.resolve(uri: uri)
      #expect(resolved == data)
    }
  }

  @Test func resolveToBase64() async throws {
    let root = try makeTempDir()
    try await withDependencies {
      $0.dataBucket = LocalDataBucket(rootDirectory: root)
    } operation: {
      let data = Data("test data".utf8)
      let uri = try await BlobBucket.store(namespace: "sess-2", data: data, mimeType: "image/jpeg")

      let base64 = try await BlobBucket.resolveToBase64(uri: uri)
      #expect(base64 == data.base64EncodedString())
    }
  }

  @Test func duplicateDataDeduplicates() async throws {
    let root = try makeTempDir()
    try await withDependencies {
      $0.dataBucket = LocalDataBucket(rootDirectory: root)
    } operation: {
      let data = Data("same content".utf8)
      let uri1 = try await BlobBucket.store(namespace: "sess-3", data: data, mimeType: "image/png")
      let uri2 = try await BlobBucket.store(namespace: "sess-3", data: data, mimeType: "image/png")

      #expect(uri1 == uri2)

      // Only one file should exist in the blobs/sess-3 subdirectory.
      let sessionDir = (root as NSString).appendingPathComponent("blobs/sess-3")
      let files = try FileManager.default.contentsOfDirectory(atPath: sessionDir)
      #expect(files.count == 1)
    }
  }

  @Test func differentNamespacesSameDataDifferentURIs() async throws {
    let root = try makeTempDir()
    try await withDependencies {
      $0.dataBucket = LocalDataBucket(rootDirectory: root)
    } operation: {
      let data = Data("shared content".utf8)
      let uri1 = try await BlobBucket.store(namespace: "sess-a", data: data, mimeType: "image/png")
      let uri2 = try await BlobBucket.store(namespace: "sess-b", data: data, mimeType: "image/png")

      #expect(uri1 != uri2)
      #expect(uri1.contains("sess-a"))
      #expect(uri2.contains("sess-b"))

      // Both should resolve to the same content.
      let resolved1 = try await BlobBucket.resolve(uri: uri1)
      let resolved2 = try await BlobBucket.resolve(uri: uri2)
      #expect(resolved1 == resolved2)
    }
  }

  @Test func invalidURIThrows() async throws {
    let root = try makeTempDir()
    try await withDependencies {
      $0.dataBucket = LocalDataBucket(rootDirectory: root)
    } operation: {
      await #expect(throws: (any Error).self) {
        _ = try await BlobBucket.resolve(uri: "not-a-blob-uri")
      }

      await #expect(throws: (any Error).self) {
        _ = try await BlobBucket.resolve(uri: "blob://")
      }
    }
  }

  @Test func mimeTypeForExtension() {
    #expect(BlobBucket.mimeTypeForExtension("png") == "image/png")
    #expect(BlobBucket.mimeTypeForExtension("jpg") == "image/jpeg")
    #expect(BlobBucket.mimeTypeForExtension("jpeg") == "image/jpeg")
    #expect(BlobBucket.mimeTypeForExtension("gif") == "image/gif")
    #expect(BlobBucket.mimeTypeForExtension("webp") == "image/webp")
    #expect(BlobBucket.mimeTypeForExtension("txt") == nil)
    #expect(BlobBucket.mimeTypeForExtension("PDF") == nil)
  }

  @Test func extensionForMimeType() {
    #expect(BlobBucket.extensionForMimeType("image/png") == "png")
    #expect(BlobBucket.extensionForMimeType("image/jpeg") == "jpg")
    #expect(BlobBucket.extensionForMimeType("image/gif") == "gif")
    #expect(BlobBucket.extensionForMimeType("image/webp") == "webp")
    #expect(BlobBucket.extensionForMimeType("application/octet-stream") == "bin")
  }

  @Test func isImageExtension() {
    #expect(BlobBucket.isImageExtension("png") == true)
    #expect(BlobBucket.isImageExtension("PNG") == true)
    #expect(BlobBucket.isImageExtension("jpg") == true)
    #expect(BlobBucket.isImageExtension("gif") == true)
    #expect(BlobBucket.isImageExtension("webp") == true)
    #expect(BlobBucket.isImageExtension("txt") == false)
    #expect(BlobBucket.isImageExtension("swift") == false)
  }
}
