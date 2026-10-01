import DependenciesTestSupport
import Foundation
import Testing

@testable import FoundationTools

private let fixedDate = Date(timeIntervalSince1970: 1000)

@Suite(
  .dependencies {
    $0.date = .constant(fixedDate)
  }
)
struct InMemoryFileStoreTests {
  // MARK: - Basic file operations

  @Test
  func writeAndRead() async throws {
    let store = InMemoryFileStore()
    let data = Data("hello".utf8)

    try await store.write(path: "/file.txt", data: data)
    let read = try await store.read(path: "/file.txt")

    #expect(read == data)
  }

  @Test
  func readNonexistent() async throws {
    let store = InMemoryFileStore()

    await #expect(throws: FileStoreError.fileNotFound("/nope.txt")) {
      try await store.read(path: "/nope.txt")
    }
  }

  @Test
  func overwriteFile() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/file.txt", data: Data("v1".utf8))
    try await store.write(path: "/file.txt", data: Data("v2".utf8))

    let read = try await store.read(path: "/file.txt")
    #expect(read == Data("v2".utf8))
  }

  // MARK: - Stat

  @Test
  func statFile() async throws {
    let store = InMemoryFileStore()
    let data = Data("hello".utf8)

    try await store.write(path: "/file.txt", data: data)
    let stat = try await store.stat(path: "/file.txt")

    #expect(stat.type == .file)
    #expect(stat.size == 5)
    #expect(stat.modificationDate == fixedDate)
  }

  @Test
  func statDirectory() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/dir")
    let stat = try await store.stat(path: "/dir")

    #expect(stat.type == .directory)
    #expect(stat.modificationDate == fixedDate)
  }

  @Test
  func statSymlinkReturnsSymlinkType() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/target.txt", data: Data("hi".utf8))
    try await store.link(path: "/link", target: "target.txt")

    // stat uses followSymlinks: false, so should report .symlink
    let stat = try await store.stat(path: "/link")
    #expect(stat.type == .symlink)
    #expect(stat.modificationDate == fixedDate)
  }

  // MARK: - Mkdir

  @Test
  func mkdirCreatesIntermediateDirectories() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/a/b/c")

    let stat = try await store.stat(path: "/a/b/c")
    #expect(stat.type == .directory)

    let statB = try await store.stat(path: "/a/b")
    #expect(statB.type == .directory)
  }

  @Test
  func mkdirIdempotent() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/dir")
    try await store.mkdir(path: "/dir") // should not throw
  }

  @Test
  func writeCreatesParentDirectories() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/a/b/file.txt", data: Data("x".utf8))
    let read = try await store.read(path: "/a/b/file.txt")

    #expect(read == Data("x".utf8))
  }

  // MARK: - List

  @Test
  func listDirectory() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/dir/a.txt", data: Data("a".utf8))
    try await store.write(path: "/dir/b.txt", data: Data("b".utf8))
    try await store.mkdir(path: "/dir/sub")

    let entries = try await store.list(path: "/dir")
    let names = Set(entries.map(\.name))

    #expect(names == ["a.txt", "b.txt", "sub"])
  }

  @Test
  func listNonDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/file.txt", data: Data())

    await #expect(throws: FileStoreError.self) {
      try await store.list(path: "/file.txt")
    }
  }

  // MARK: - Delete

  @Test
  func deleteFile() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/file.txt", data: Data("x".utf8))

    try await store.delete(path: "/file.txt")

    await #expect(throws: FileStoreError.self) {
      try await store.read(path: "/file.txt")
    }
  }

  @Test
  func deleteDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir/sub")
    try await store.write(path: "/dir/sub/file.txt", data: Data())

    try await store.delete(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.stat(path: "/dir")
    }
  }

  @Test
  func cannotDeleteRoot() async throws {
    let store = InMemoryFileStore()

    await #expect(throws: FileStoreError.cannotDeleteRoot) {
      try await store.delete(path: "/")
    }
  }

  // MARK: - Symlinks

  @Test
  func readThroughSymlink() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/real.txt", data: Data("content".utf8))
    try await store.link(path: "/link", target: "real.txt")

    let read = try await store.read(path: "/link")
    #expect(read == Data("content".utf8))
  }

  @Test
  func symlinkRelativeResolution() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/a/target.txt", data: Data("found".utf8))

    // Link at /a/b/link -> ../target.txt should resolve to /a/target.txt
    try await store.mkdir(path: "/a/b")
    try await store.link(path: "/a/b/link", target: "../target.txt")

    let read = try await store.read(path: "/a/b/link")
    #expect(read == Data("found".utf8))
  }

  @Test
  func listThroughSymlinkedDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/real/file.txt", data: Data("x".utf8))

    // Link at /link -> real, then list /link
    try await store.link(path: "/link", target: "real")

    let entries = try await store.list(path: "/link")
    #expect(entries.map(\.name) == ["file.txt"])
  }

  @Test
  func deleteSymlinkDoesNotDeleteTarget() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/target.txt", data: Data("keep".utf8))
    try await store.link(path: "/link", target: "target.txt")

    try await store.delete(path: "/link")

    // Target should still exist
    let read = try await store.read(path: "/target.txt")
    #expect(read == Data("keep".utf8))

    // Link should be gone
    await #expect(throws: FileStoreError.self) {
      try await store.stat(path: "/link")
    }
  }

  // MARK: - Error cases

  @Test
  func writeOverDirectoryFails() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.write(path: "/dir", data: Data("x".utf8))
    }
  }

  @Test
  func readDirectoryFails() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.read(path: "/dir")
    }
  }
}
