import Foundation

public extension FileIO {
  static var real: FileIO {
    FileIO(
      stat: { path in
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let type: FileStat.NodeType = switch attrs[.type] as? FileAttributeType {
        case .typeRegular: .file
        case .typeDirectory: .directory
        case .typeSymbolicLink: .symlink
        default: .other
        }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = attrs[.modificationDate] as? Date
        return FileStat(type: type, size: size, modificationDate: mtime)
      },
      open: { path in
        let handle: Foundation.FileHandle = try Foundation.FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        return FileHandle(
          read: { length in
            handle.readData(ofLength: length)
          },
          seek: { offset in
            handle.seek(toFileOffset: UInt64(offset))
          },
          close: {
            try handle.close()
          },
        )
      },
      write: { path, data in
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      },
      list: { path in
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        return names.map { name in
          let full = (path as NSString).appendingPathComponent(name)
          var isDir: ObjCBool = false
          fm.fileExists(atPath: full, isDirectory: &isDir)
          let type: FileStat.NodeType = isDir.boolValue ? .directory : .file
          return DirectoryEntry(name: name, type: type)
        }
      },
      mkdir: { path in
        try FileManager.default.createDirectory(
          atPath: path,
          withIntermediateDirectories: true,
        )
      },
      delete: { path in
        try FileManager.default.removeItem(atPath: path)
      },
      link: { path, target in
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
      },
    )
  }
}
