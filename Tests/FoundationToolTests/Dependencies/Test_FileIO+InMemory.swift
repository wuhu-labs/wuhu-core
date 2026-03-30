import DependenciesTestSupport
import Foundation
import Testing

@testable import FoundationTools

@Suite
struct InMemoryFileStoreTests {
  // MARK: - Basic file operations

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func writeAndRead() async throws {
    let store = InMemoryFileStore()
    let data = Data("hello".utf8)

    try await store.write(path: "/file.txt", data: data)
    let read = try await store.read(path: "/file.txt")

    #expect(read == data)
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func readNonexistent() async throws {
    let store = InMemoryFileStore()

    await #expect(throws: FileStoreError.fileNotFound("/nope.txt")) {
      try await store.read(path: "/nope.txt")
    }
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func overwriteFile() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/file.txt", data: Data("v1".utf8))
    try await store.write(path: "/file.txt", data: Data("v2".utf8))

    let read = try await store.read(path: "/file.txt")
    #expect(read == Data("v2".utf8))
  }

  // MARK: - Stat

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func statFile() async throws {
    let store = InMemoryFileStore()
    let data = Data("hello".utf8)

    try await store.write(path: "/file.txt", data: data)
    let stat = try await store.stat(path: "/file.txt")

    #expect(stat.type == .file)
    #expect(stat.size == 5)
    #expect(stat.modificationDate == Date(timeIntervalSince1970: 1000))
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func statDirectory() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/dir")
    let stat = try await store.stat(path: "/dir")

    #expect(stat.type == .directory)
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func statSymlinkReturnsSymlinkType() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/target.txt", data: Data("hi".utf8))
    try await store.link(path: "/link", target: "target.txt")

    // stat uses followSymlinks: false, so should report .symlink
    let stat = try await store.stat(path: "/link")
    #expect(stat.type == .symlink)
  }

  // MARK: - Mkdir

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func mkdirCreatesIntermediateDirectories() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/a/b/c")

    let stat = try await store.stat(path: "/a/b/c")
    #expect(stat.type == .directory)

    let statB = try await store.stat(path: "/a/b")
    #expect(statB.type == .directory)
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func mkdirIdempotent() async throws {
    let store = InMemoryFileStore()

    try await store.mkdir(path: "/dir")
    try await store.mkdir(path: "/dir") // should not throw
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func writeCreatesParentDirectories() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/a/b/file.txt", data: Data("x".utf8))
    let read = try await store.read(path: "/a/b/file.txt")

    #expect(read == Data("x".utf8))
  }

  // MARK: - List

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func listDirectory() async throws {
    let store = InMemoryFileStore()

    try await store.write(path: "/dir/a.txt", data: Data("a".utf8))
    try await store.write(path: "/dir/b.txt", data: Data("b".utf8))
    try await store.mkdir(path: "/dir/sub")

    let entries = try await store.list(path: "/dir")
    let names = Set(entries.map(\.name))

    #expect(names == ["a.txt", "b.txt", "sub"])
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func listNonDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/file.txt", data: Data())

    await #expect(throws: FileStoreError.self) {
      try await store.list(path: "/file.txt")
    }
  }

  // MARK: - Delete

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func deleteFile() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/file.txt", data: Data("x".utf8))

    try await store.delete(path: "/file.txt")

    await #expect(throws: FileStoreError.self) {
      try await store.read(path: "/file.txt")
    }
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func deleteDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir/sub")
    try await store.write(path: "/dir/sub/file.txt", data: Data())

    try await store.delete(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.stat(path: "/dir")
    }
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func cannotDeleteRoot() async throws {
    let store = InMemoryFileStore()

    await #expect(throws: FileStoreError.cannotDeleteRoot) {
      try await store.delete(path: "/")
    }
  }

  // MARK: - Symlinks

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func readThroughSymlink() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/real.txt", data: Data("content".utf8))
    try await store.link(path: "/link", target: "real.txt")

    let read = try await store.read(path: "/link")
    #expect(read == Data("content".utf8))
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func symlinkRelativeResolution() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/a/target.txt", data: Data("found".utf8))

    // Link at /a/b/link -> ../target.txt should resolve to /a/target.txt
    try await store.mkdir(path: "/a/b")
    try await store.link(path: "/a/b/link", target: "../target.txt")

    let read = try await store.read(path: "/a/b/link")
    #expect(read == Data("found".utf8))
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func listThroughSymlinkedDirectory() async throws {
    let store = InMemoryFileStore()
    try await store.write(path: "/real/file.txt", data: Data("x".utf8))

    // Link at /link -> real, then list /link
    try await store.link(path: "/link", target: "real")

    let entries = try await store.list(path: "/link")
    #expect(entries.map(\.name) == ["file.txt"])
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
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

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func writeOverDirectoryFails() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.write(path: "/dir", data: Data("x".utf8))
    }
  }

  @Test(
    .dependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    }
  )
  func readDirectoryFails() async throws {
    let store = InMemoryFileStore()
    try await store.mkdir(path: "/dir")

    await #expect(throws: FileStoreError.self) {
      try await store.read(path: "/dir")
    }
  }
}
