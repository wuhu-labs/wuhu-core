import Dependencies
import Foundation
import Testing
import WuhuAPI
@testable import WuhuCore

// MARK: - LocalRunner Tests

struct LocalRunnerTests {
  @Test func localRunnerHasLocalID() {
    let runner = LocalRunner()
    #expect(runner.id == .local)
  }

  @Test func localRunnerReadWriteString() async throws {
    let io = InMemoryFileIO()
    let runner = LocalRunner()
    let path = "/tmp/test-runner-\(UUID().uuidString)/hello.txt"

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      try await runner.writeString(path: path, content: "Hello, runner!", createIntermediateDirectories: true, encoding: .utf8)
      let result = try await runner.readString(path: path, encoding: .utf8)
      #expect(result == "Hello, runner!")
    }
  }

  @Test func localRunnerExists() async throws {
    let io = InMemoryFileIO()
    io.seedFile(path: "/workspace/file.txt", content: "content")
    io.seedDirectory(path: "/workspace/subdir")
    let runner = LocalRunner()

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let fileResult = try await runner.exists(path: "/workspace/file.txt")
      #expect(fileResult == .file)

      let dirResult = try await runner.exists(path: "/workspace/subdir")
      #expect(dirResult == .directory)

      let missingResult = try await runner.exists(path: "/workspace/nope")
      #expect(missingResult == .notFound)
    }
  }

  @Test func localRunnerListDirectory() async throws {
    let io = InMemoryFileIO()
    io.seedDirectory(path: "/workspace")
    io.seedFile(path: "/workspace/a.txt", content: "a")
    io.seedFile(path: "/workspace/b.txt", content: "b")
    io.seedDirectory(path: "/workspace/subdir")
    let runner = LocalRunner()

    try await withDependencies {
      $0.fileIO = io
    } operation: {
      let entries = try await runner.listDirectory(path: "/workspace")
      let names = entries.map(\.name).sorted()
      #expect(names.contains("a.txt"))
      #expect(names.contains("b.txt"))
      #expect(names.contains("subdir"))
      let subdirEntry = entries.first { $0.name == "subdir" }
      #expect(subdirEntry?.isDirectory == true)
    }
  }

  @Test func localRunnerStartBashAndWait() async throws {
    let runner = LocalRunner()
    let tmpDir = NSTemporaryDirectory() + "wuhu-runner-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let tag = "test-bash-\(UUID().uuidString)"
    let started = try await runner.startBash(tag: tag, command: "echo hello", cwd: tmpDir, timeout: 5)
    #expect(!started.alreadyRunning)
    let result = try await runner.waitForBashResult(tag: tag)
    #expect(result.exitCode == 0)
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(!result.timedOut)
    if let path = result.fullOutputPath { try? FileManager.default.removeItem(atPath: path) }
  }

  @Test func localRunnerStartBashIdempotent() async throws {
    let runner = LocalRunner()
    let tmpDir = NSTemporaryDirectory() + "wuhu-runner-test-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let tag = "test-idempotent-\(UUID().uuidString)"
    let first = try await runner.startBash(tag: tag, command: "sleep 1", cwd: tmpDir, timeout: 5)
    #expect(!first.alreadyRunning)
    let second = try await runner.startBash(tag: tag, command: "sleep 1", cwd: tmpDir, timeout: 5)
    #expect(second.alreadyRunning)
    _ = try await runner.cancelBash(tag: tag)
  }

  @Test func localRunnerCancelBash() async throws {
    let runner = LocalRunner()
    let tmpDir = NSTemporaryDirectory() + "wuhu-runner-cancel-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let tag = "test-cancel-\(UUID().uuidString)"
    _ = try await runner.startBash(tag: tag, command: "sleep 60", cwd: tmpDir, timeout: nil)

    // Give it a moment to start
    try await Task.sleep(for: .milliseconds(50))

    let cancel = try await runner.cancelBash(tag: tag)
    #expect(cancel.cancelled)

    // waitForBashResult should deliver terminated=true
    let result = try await runner.waitForBashResult(tag: tag)
    #expect(result.terminated)
  }

  @Test func localRunnerMaterializeCopiesTemplate() async throws {
    let fm = FileManager.default
    let runner = LocalRunner()
    let base = NSTemporaryDirectory() + "wuhu-runner-materialize-\(UUID().uuidString)"
    let templateDir = base + "/template"
    let workspacesDir = base + "/workspaces"
    try fm.createDirectory(atPath: templateDir, withIntermediateDirectories: true)
    try "# README".write(toFile: templateDir + "/README.md", atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(atPath: base) }

    let result = try await runner.materialize(params: MaterializeRequest(
      templatePath: templateDir,
      destinationPath: workspacesDir + "/sess-1",
    ))
    #expect(result.workspacePath == workspacesDir + "/sess-1")
    #expect(fm.fileExists(atPath: result.workspacePath + "/README.md"))
    let content = try String(contentsOfFile: result.workspacePath + "/README.md", encoding: .utf8)
    #expect(content == "# README")
  }

  @Test func localRunnerMaterializeFailsForMissingTemplate() async throws {
    let runner = LocalRunner()
    do {
      _ = try await runner.materialize(params: MaterializeRequest(
        templatePath: "/nonexistent-\(UUID().uuidString)",
        destinationPath: "/tmp/should-not-exist",
      ))
      Issue.record("Should have thrown")
    } catch {
      #expect(String(describing: error).contains("not found") || String(describing: error).contains("File not found"))
    }
  }
}

// MARK: - InMemoryRunnerCommands Tests

struct InMemoryRunnerCommandsTests {
  @Test func startBashAndWait() async throws {
    let runner = InMemoryRunnerCommands()
    await runner.stubBash(pattern: "echo test", result: BashResult(exitCode: 0, output: "test\n", timedOut: false, terminated: false))

    let tag = "t1"
    let started = try await runner.startBash(tag: tag, command: "echo test", cwd: "/", timeout: nil)
    #expect(!started.alreadyRunning)
    let result = try await runner.waitForBashResult(tag: tag)
    #expect(result.exitCode == 0)
    #expect(result.output == "test\n")
  }

  @Test func startBashIdempotent() async throws {
    let runner = InMemoryRunnerCommands()
    let tag = "t2"
    _ = try await runner.startBash(tag: tag, command: "slow", cwd: "/", timeout: nil)
    let second = try await runner.startBash(tag: tag, command: "slow", cwd: "/", timeout: nil)
    #expect(second.alreadyRunning)
    _ = try await runner.waitForBashResult(tag: tag)
  }

  @Test func cancelBash() async throws {
    let runner = InMemoryRunnerCommands()
    let tag = "t3"
    _ = try await runner.startBash(tag: tag, command: "any", cwd: "/", timeout: nil)
    let cancel = try await runner.cancelBash(tag: tag)
    #expect(cancel.cancelled)
    // Result should be terminated
    let result = try await runner.waitForBashResult(tag: tag)
    #expect(result.terminated)
  }

  @Test func fileOps() async throws {
    let runner = InMemoryRunnerCommands()
    await runner.seedDirectory(path: "/workspace")
    await runner.seedFile(path: "/workspace/hello.txt", content: "hello")

    let exists = try await runner.exists(path: "/workspace/hello.txt")
    #expect(exists == .file)

    let content = try await runner.readString(path: "/workspace/hello.txt", encoding: .utf8)
    #expect(content == "hello")

    try await runner.writeString(path: "/workspace/new.txt", content: "new", createIntermediateDirectories: false, encoding: .utf8)
    let newContent = await runner.fileContent(path: "/workspace/new.txt")
    #expect(newContent == "new")
  }
}

// MARK: - RunnerID Wire Encoding Tests

struct RunnerIDWireEncodingTests {
  @Test func runnerIDWireEncoding() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let localData = try encoder.encode(RunnerID.local)
    let localDecoded = try decoder.decode(RunnerID.self, from: localData)
    #expect(localDecoded == .local)
    #expect(String(decoding: localData, as: UTF8.self) == "\"local\"")

    let remoteData = try encoder.encode(RunnerID.remote(name: "build-mac"))
    let remoteDecoded = try decoder.decode(RunnerID.self, from: remoteData)
    #expect(remoteDecoded == .remote(name: "build-mac"))
    #expect(String(decoding: remoteData, as: UTF8.self) == "\"remote:build-mac\"")
  }
}

// MARK: - RunnerRegistry Tests

struct RunnerRegistryTests {
  @Test func registryLocalNotPresentByDefault() async {
    let registry = RunnerRegistry()
    let local = await registry.get(.local)
    #expect(local == nil)
  }

  @Test func registryLocalAvailableWhenRegistered() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
    let local = await registry.get(.local)
    #expect(local != nil)
    #expect(local?.id == .local)
  }

  @Test func registryRegisterAndGet() async {
    let registry = RunnerRegistry()
    let mem = InMemoryRunnerCommands(id: .remote(name: "build-linux"))
    await registry.register(mem)

    let fetched = await registry.get(.remote(name: "build-linux"))
    #expect(fetched != nil)
    #expect(fetched?.id == .remote(name: "build-linux"))
  }

  @Test func registryRemoveRemote() async {
    let registry = RunnerRegistry()
    let mem = InMemoryRunnerCommands(id: .remote(name: "temp"))
    await registry.register(mem)
    #expect(await registry.isAvailable(.remote(name: "temp")))

    await registry.remove(.remote(name: "temp"))
    let stillAvailable = await registry.isAvailable(.remote(name: "temp"))
    #expect(!stillAvailable)
  }

  @Test func registryCanRemoveLocal() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
    #expect(await registry.isAvailable(.local))
    await registry.remove(.local)
    let stillAvailable = await registry.isAvailable(.local)
    #expect(!stillAvailable)
  }

  @Test func registryListNames() async {
    let registry = RunnerRegistry()
    let mem1 = InMemoryRunnerCommands(id: .remote(name: "alpha"))
    let mem2 = InMemoryRunnerCommands(id: .remote(name: "beta"))
    await registry.register(mem1)
    await registry.register(mem2)

    let names = await registry.listRunnerNames()
    #expect(!names.contains("local"))
    #expect(names.contains("alpha"))
    #expect(names.contains("beta"))
  }

  @Test func registryListNamesWithLocal() async {
    let registry = RunnerRegistry(runners: [LocalRunner()])
    let mem1 = InMemoryRunnerCommands(id: .remote(name: "alpha"))
    await registry.register(mem1)

    let names = await registry.listRunnerNames()
    #expect(names.contains("local"))
    #expect(names.contains("alpha"))
  }
}
