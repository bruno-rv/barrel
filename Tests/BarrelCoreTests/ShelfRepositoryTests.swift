import Foundation
import XCTest
@testable import BarrelCore

final class ShelfRepositoryTests: XCTestCase {
  private let fileManager = FileManager.default
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testLoadMigratesLegacyManifestWithoutLosingItsItem() async throws {
    let root = try makeRoot()
    let manifest = Data(#"[{"id":"60D1B05E-40A3-433D-9B25-587EB5E35C51","title":"Brief","kind":"file","createdAt":"2026-07-10T10:00:00Z","updatedAt":"2026-07-10T10:00:00Z","fileName":"Brief.pdf","relativePath":"Items/1/Brief.pdf","text":null,"children":[]}]"#.utf8)
    try manifest.write(to: root.appendingPathComponent("shelf.json"))
    let repository = ShelfRepository(configuration: configuration(root: root))

    let loaded = try await repository.load()

    XCTAssertEqual(loaded.count, 1)
    XCTAssertEqual(loaded.first?.title, "Brief")
    XCTAssertEqual(loaded.first?.origin, .imported)
    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot, loaded)
  }

  func testFailedManifestWriteRollsBackStagedAndManagedFiles() async throws {
    let root = try makeRoot()
    let source = root.deletingLastPathComponent().appendingPathComponent("source-\(UUID()).txt")
    try Data("hello".utf8).write(to: source)
    addTeardownBlock { try? FileManager.default.removeItem(at: source) }
    let repository = ShelfRepository(
      configuration: configuration(root: root) { _, _ in throw TestError.writeFailed }
    )

    let outcome = await repository.importFiles([source], origin: .imported, expiresAt: nil)

    XCTAssertTrue(outcome.successes.isEmpty)
    XCTAssertEqual(outcome.failures.map(\.url), [source])
    XCTAssertEqual(try descendantFiles(in: root.appendingPathComponent("Staging")), [])
    XCTAssertEqual(try descendantFiles(in: root.appendingPathComponent("Items")), [])
    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot, [])
  }

  func testCorruptManifestIsPreservedBeforeLoadThrows() async throws {
    let root = try makeRoot()
    try Data("not json".utf8).write(to: root.appendingPathComponent("shelf.json"))
    let repository = ShelfRepository(configuration: configuration(root: root))

    do {
      _ = try await repository.load()
      XCTFail("Expected corrupt manifest error")
    } catch RepositoryError.corruptManifest {
      // Expected.
    }

    let backups = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("shelf-corrupt-") && $0.pathExtension == "json" }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: backups[0]), Data("not json".utf8))
  }

  func testEqualFilesShareOneManagedFile() async throws {
    let root = try makeRoot()
    let firstSource = try makeSource(named: "first.txt", contents: "same bytes")
    let secondSource = try makeSource(named: "second.txt", contents: "same bytes")
    let repository = ShelfRepository(configuration: configuration(root: root))

    let outcome = await repository.importFiles(
      [firstSource, secondSource],
      origin: .imported,
      expiresAt: nil
    )

    XCTAssertEqual(outcome.successes.count, 2)
    XCTAssertTrue(outcome.failures.isEmpty)
    XCTAssertEqual(Set(outcome.successes.compactMap(\.relativePath)).count, 1)
    XCTAssertEqual(Set(outcome.successes.compactMap(\.contentHash)).count, 1)
    XCTAssertEqual(try descendantFiles(in: root.appendingPathComponent("Items")).count, 1)
  }

  func testUnreadableImportDoesNotDiscardSuccessfulImport() async throws {
    let root = try makeRoot()
    let readable = try makeSource(named: "readable.txt", contents: "available")
    let missing = fileManager.temporaryDirectory.appendingPathComponent("missing-\(UUID()).txt")
    let repository = ShelfRepository(configuration: configuration(root: root))

    let outcome = await repository.importFiles(
      [missing, readable],
      origin: .imported,
      expiresAt: nil
    )

    XCTAssertEqual(outcome.successes.map(\.title), ["readable"])
    XCTAssertEqual(outcome.failures.map(\.url), [missing])
    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot, outcome.successes)
  }

  func testTrashAndRestorePreserveManagedFile() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "keep.txt", contents: "keep me")
    let repository = ShelfRepository(configuration: configuration(root: root))
    let outcome = await repository.importFiles([source], origin: .imported, expiresAt: nil)
    let item = try XCTUnwrap(outcome.successes.first)
    let resolvedFileURL = await repository.fileURL(for: item)
    let fileURL = try XCTUnwrap(resolvedFileURL)

    try await repository.trash(ids: [item.id])
    var snapshot = await repository.snapshot()
    XCTAssertNotNil(snapshot.first?.trashedAt)
    XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))

    try await repository.restore(ids: [item.id])
    snapshot = await repository.snapshot()
    XCTAssertNil(snapshot.first?.trashedAt)
    XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
  }

  func testEmptyTrashKeepsFileReferencedByLiveDuplicate() async throws {
    let root = try makeRoot()
    let firstSource = try makeSource(named: "first.txt", contents: "shared")
    let secondSource = try makeSource(named: "second.txt", contents: "shared")
    let repository = ShelfRepository(configuration: configuration(root: root))
    let outcome = await repository.importFiles(
      [firstSource, secondSource],
      origin: .imported,
      expiresAt: nil
    )
    let first = try XCTUnwrap(outcome.successes.first)
    let second = try XCTUnwrap(outcome.successes.last)
    let resolvedFileURL = await repository.fileURL(for: first)
    let sharedFileURL = try XCTUnwrap(resolvedFileURL)

    try await repository.trash(ids: [first.id])
    try await repository.emptyTrash()

    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.map(\.id), [second.id])
    XCTAssertTrue(fileManager.fileExists(atPath: sharedFileURL.path))
  }

  func testLoadRemovesUnreferencedManagedDirectory() async throws {
    let root = try makeRoot()
    let orphanDirectory = root
      .appendingPathComponent("Items", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
    try Data("orphan".utf8).write(to: orphanDirectory.appendingPathComponent("orphan.txt"))
    let repository = ShelfRepository(configuration: configuration(root: root))

    _ = try await repository.load()

    XCTAssertFalse(fileManager.fileExists(atPath: orphanDirectory.path))
  }

  func testCleanupTrashesExpiredClipboardButKeepsPinnedItemLive() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let expiration = now.addingTimeInterval(-1)
    let expired = try await repository.addText(
      "Expired",
      kind: .text,
      origin: .clipboard,
      expiresAt: expiration
    )
    let pinned = try await repository.addText(
      "Pinned",
      kind: .text,
      origin: .clipboard,
      expiresAt: expiration
    )
    try await repository.setPinned(id: pinned.id, isPinned: true)

    try await repository.cleanup()

    let snapshot = await repository.snapshot()
    XCTAssertNotNil(snapshot.first(where: { $0.id == expired.id })?.trashedAt)
    XCTAssertNil(snapshot.first(where: { $0.id == pinned.id })?.trashedAt)
    XCTAssertTrue(snapshot.first(where: { $0.id == pinned.id })?.isPinned == true)
  }

  func testTextStackSplitAndMetadataMutationsPersist() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let first = try await repository.addText("First", kind: .text, origin: .imported, expiresAt: nil)
    let second = try await repository.addText("https://example.com", kind: .link, origin: .shortcut, expiresAt: nil)
    let expiration = now.addingTimeInterval(3_600)

    try await repository.rename(id: first.id, title: "Renamed")
    try await repository.setExpiration(id: first.id, date: expiration)
    try await repository.setPinned(id: first.id, isPinned: true)
    let stack = try await repository.stack(ids: [first.id, second.id])

    var snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.map(\.id), [stack.id])
    XCTAssertEqual(stack.children.count, 2)
    XCTAssertEqual(stack.children.first(where: { $0.id == first.id })?.title, "Renamed")
    XCTAssertEqual(stack.children.first(where: { $0.id == first.id })?.expiresAt, expiration)
    XCTAssertTrue(stack.children.first(where: { $0.id == first.id })?.isPinned == true)

    try await repository.split(id: stack.id)
    snapshot = await repository.snapshot()
    XCTAssertEqual(Set(snapshot.map(\.id)), Set([first.id, second.id]))
  }

  func testStorageUsageCountsManagedFileBytesOnce() async throws {
    let root = try makeRoot()
    let firstSource = try makeSource(named: "first.txt", contents: "123456")
    let secondSource = try makeSource(named: "second.txt", contents: "123456")
    let repository = ShelfRepository(configuration: configuration(root: root))
    _ = await repository.importFiles([firstSource, secondSource], origin: .imported, expiresAt: nil)

    let usage = try await repository.storageUsage()
    XCTAssertEqual(usage, 6)
  }

  private func configuration(
    root: URL,
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter
  ) -> RepositoryConfiguration {
    let now = now
    return RepositoryConfiguration(
      rootURL: root,
      deviceID: "test-mac",
      quotaBytes: 1_073_741_824,
      trashRetention: 604_800,
      now: { now },
      manifestWriter: manifestWriter
    )
  }

  private func makeRoot() throws -> URL {
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func makeSource(named name: String, contents: String) throws -> URL {
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("BarrelCoreTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: source)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return source
  }

  private func descendantFiles(in directory: URL) throws -> [URL] {
    guard fileManager.fileExists(atPath: directory.path) else {
      return []
    }
    let keys: [URLResourceKey] = [.isRegularFileKey]
    let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys)
    return (enumerator?.allObjects as? [URL] ?? []).filter {
      (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
    }
  }

  private enum TestError: Error {
    case writeFailed
  }
}
