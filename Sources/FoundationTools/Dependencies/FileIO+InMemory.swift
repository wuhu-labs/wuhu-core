import Dependencies
import Foundation
import Synchronization

// MARK: - File system tree

private extension String {
  var pathComponents: [String] {
    assert(starts(with: "/"), "Path must be absolute")
    return URL(fileURLWithPath: self).standardizedFileURL.path.split(separator: "/").map(String.init)
  }
}

private final class FSNode {
  enum Payload {
    case file(Data)
    case directory([String: FSNode])
    case symlink(String)
  }

  var payload: Payload
  var mtime: Date

  init(payload: Payload, mtime: Date) {
    self.payload = payload
    self.mtime = mtime
  }

  var size: Int {
    switch payload {
    case let .file(data):
      data.count
    case .directory:
      128
    case let .symlink(target):
      target.utf8.count
    }
  }

  var type: FileStat.NodeType {
    switch payload {
    case .file: .file
    case .directory: .directory
    case .symlink: .symlink
    }
  }
}

private struct FSWalker {
  struct Element {
    let node: FSNode
    let linkTarget: FSNode?
    let component: String
  }

  let root: FSNode
  let followSymlinks: Bool
  private(set) var elements: [Element] = []

  var current: FSNode {
    if let last = elements.last {
      return last.linkTarget ?? last.node
    }
    return root
  }

  var currentPath: String {
    "/" + elements.map(\.component).joined(separator: "/")
  }

  func getChild(name: String) throws -> FSNode? {
    guard case let .directory(children) = current.payload else {
      throw FileStoreError.notADirectory(currentPath)
    }
    return children[name]
  }

  func setChild(name: String, node: FSNode?, mtime: Date) throws {
    guard case var .directory(children) = current.payload else {
      throw FileStoreError.notADirectory(currentPath)
    }
    children[name] = node
    current.payload = .directory(children)
    current.mtime = mtime
  }

  mutating func walk(component: String) throws {
    assert(!component.contains("/"), "Component must not contain /")

    guard case let .directory(children) = current.payload else {
      throw FileStoreError.notADirectory(currentPath)
    }
    guard let child = children[component] else {
      let combinedPath = currentPath + "/" + component
      throw FileStoreError.fileNotFound(URL(filePath: combinedPath).standardizedFileURL.path)
    }

    guard followSymlinks, case let .symlink(link) = child.payload else {
      elements.append(Element(node: child, linkTarget: nil, component: component))
      return
    }

    let combinedPath = URL(filePath: currentPath).appendingPathComponent(link).path
    let linkTarget = try Self.goto(path: combinedPath, of: root, followSymlinks: true).current
    elements.append(Element(node: child, linkTarget: linkTarget, component: component))
  }

  func parent() -> FSWalker? {
    guard !elements.isEmpty else { return nil }
    return FSWalker(root: root, followSymlinks: followSymlinks, elements: Array(elements.dropLast()))
  }

  static func goto(path: String, of root: FSNode, followSymlinks: Bool) throws -> FSWalker {
    assert(path.starts(with: "/"), "Path must be absolute")
    let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.path.split(separator: "/").map(String.init)
    var walker = FSWalker(root: root, followSymlinks: followSymlinks)
    for component in pathComponents {
      try walker.walk(component: component)
    }
    return walker
  }
}

// MARK: - InMemoryFileStore

public actor InMemoryFileStore {
  private let root: FSNode

  @Dependency(\.date)
  private var date

  public init() {
    root = FSNode(payload: .directory([:]), mtime: Date())
  }

  public func stat(path: String) throws -> FileStat {
    let node = try FSWalker.goto(path: path, of: root, followSymlinks: false).current
    return FileStat(
      type: node.type,
      size: node.size,
      modificationDate: node.mtime,
    )
  }

  public func read(path: String) throws -> Data {
    let node = try FSWalker.goto(path: path, of: root, followSymlinks: true).current
    guard case let .file(data) = node.payload else {
      throw FileStoreError.notAFile(path)
    }
    return data
  }

  private func ensureParentDirectory(path: String) throws -> (FSWalker, String) {
    let pathComponents = path.pathComponents
    let parentPath = "/" + pathComponents.dropLast().joined(separator: "/")
    assert(!pathComponents.isEmpty)
    try mkdir(path: parentPath)

    let walker = try FSWalker.goto(path: parentPath, of: root, followSymlinks: true)
    let childName = pathComponents.last!
    // Overwrite is okay as long as it is not a directory.
    if let child = try walker.getChild(name: childName) {
      guard child.type != .directory else {
        throw FileStoreError.fileExists(path)
      }
    }

    return (walker, childName)
  }

  public func write(path: String, data: Data) throws {
    let (parent, name) = try ensureParentDirectory(path: path)
    let now = date()
    try parent.setChild(name: name, node: FSNode(payload: .file(data), mtime: now), mtime: now)
  }

  public func link(path: String, target: String) throws {
    let (parent, name) = try ensureParentDirectory(path: path)
    let now = date()
    try parent.setChild(name: name, node: FSNode(payload: .symlink(target), mtime: now), mtime: now)
  }

  public func mkdir(path: String) throws {
    let pathComponents = path.pathComponents
    var walker = FSWalker(root: root, followSymlinks: true)

    let now = date()
    for component in pathComponents {
      if try walker.getChild(name: component) == nil {
        try walker.setChild(name: component, node: FSNode(payload: .directory([:]), mtime: now), mtime: now)
      }

      try walker.walk(component: component)
    }

    // .getChild checks if it is a directory, but we need to check the final one.
    guard walker.current.type == .directory else {
      throw FileStoreError.fileExists(path)
    }
  }

  public func list(path: String) throws -> [DirectoryEntry] {
    let walker = try FSWalker.goto(path: path, of: root, followSymlinks: true)
    guard case let .directory(children) = walker.current.payload else {
      throw FileStoreError.notADirectory(path)
    }
    return children.map { name, child in
      DirectoryEntry(name: name, type: child.type)
    }
  }

  public func delete(path: String) throws {
    let walker = try FSWalker.goto(path: path, of: root, followSymlinks: true)
    guard let parent = walker.parent() else {
      throw FileStoreError.cannotDeleteRoot
    }
    try parent.setChild(name: walker.elements.last!.component, node: nil, mtime: date())
  }
}

// MARK: - FileIO.inMemory

public extension FileIO {
  static func inMemory(_ store: InMemoryFileStore) -> FileIO {
    FileIO(
      stat: { path in
        try await store.stat(path: path)
      },
      open: { path in
        let data = try await store.read(path: path)
        var offset = 0
        return FileHandle(
          read: { length in
            let end = min(offset + length, data.count)
            let chunk = data[offset ..< end]
            offset = end
            return Data(chunk)
          },
          seek: { newOffset in
            offset = min(newOffset, data.count)
          },
          close: {},
        )
      },
      write: { path, data in
        try await store.write(path: path, data: data)
      },
      list: { path in
        try await store.list(path: path)
      },
      mkdir: { path in
        try await store.mkdir(path: path)
      },
      delete: { path in
        try await store.delete(path: path)
      },
      link: { path, target in
        try await store.link(path: path, target: target)
      },
    )
  }
}

// MARK: - Errors

public enum FileStoreError: Equatable, Error, Sendable, CustomStringConvertible {
  case fileNotFound(String)
  case directoryNotFound(String)
  case notAFile(String)
  case notADirectory(String)
  case fileExists(String)
  case cannotDeleteRoot

  public var description: String {
    switch self {
    case let .fileNotFound(p): "File not found: \(p)"
    case let .directoryNotFound(p): "Directory not found: \(p)"
    case let .notAFile(p): "Not a file: \(p)"
    case let .notADirectory(p): "Not a directory: \(p)"
    case let .fileExists(p): "File exists: \(p)"
    case .cannotDeleteRoot: "Cannot delete root"
    }
  }
}
