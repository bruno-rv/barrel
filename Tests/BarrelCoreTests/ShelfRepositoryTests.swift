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
      configuration: configuration(
        root: root,
        manifestWriter: { _, _ in throw TestError.writeFailed }
      )
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

  func testTrashingAnAlreadyTrashedItemPreservesOriginalDeletionDate() async throws {
    let root = try makeRoot()
    let clock = TestClock(now)
    let repository = ShelfRepository(configuration: configuration(root: root, now: { clock.date }))
    let item = try await repository.addText(
      "Keep original trash date",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )

    try await repository.trash(ids: [item.id])
    clock.date = now.addingTimeInterval(3_600)
    try await repository.trash(ids: [item.id])

    let snapshot = await repository.snapshot()
    let trashed = try XCTUnwrap(snapshot.first)
    XCTAssertEqual(trashed.trashedAt, now)
    XCTAssertEqual(trashed.revision, item.revision + 1)
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

  func testDeletePermanentlyRemovesOnlySelectedTrashItem() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let first = try await repository.addText("First", kind: .text, origin: .imported, expiresAt: nil)
    let second = try await repository.addText("Second", kind: .text, origin: .imported, expiresAt: nil)
    try await repository.trash(ids: [first.id, second.id])

    try await repository.deletePermanently(ids: [first.id])

    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.map(\.id), [second.id])
    XCTAssertNotNil(snapshot.first?.trashedAt)
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

  func testQuotaCleanupCountsDeduplicatedManagedFileOnce() async throws {
    let root = try makeRoot()
    let firstSource = try makeSource(named: "first.txt", contents: "123456")
    let secondSource = try makeSource(named: "second.txt", contents: "123456")
    let repository = ShelfRepository(configuration: configuration(root: root, quotaBytes: 6))
    let outcome = await repository.importFiles(
      [firstSource, secondSource],
      origin: .clipboard,
      expiresAt: nil
    )
    XCTAssertEqual(outcome.successes.count, 2)

    try await repository.cleanup()

    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.count, 2)
    XCTAssertTrue(snapshot.allSatisfy { $0.trashedAt == nil })
  }

  func testUpdatedStorageQuotaIsUsedByCleanup() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "clipboard.txt", contents: "123456")
    let repository = ShelfRepository(configuration: configuration(root: root, quotaBytes: 100))
    let outcome = await repository.importFiles([source], origin: .clipboard, expiresAt: nil)
    let item = try XCTUnwrap(outcome.successes.first)

    await repository.setStorageQuota(0)
    try await repository.cleanup()

    let snapshot = await repository.snapshot()
    XCTAssertNotNil(snapshot.first(where: { $0.id == item.id })?.trashedAt)
  }

  func testCleanupReportsWhenPhysicalUsageRemainsAboveQuota() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "clipboard.txt", contents: "123456")
    let repository = ShelfRepository(configuration: configuration(root: root, quotaBytes: 0))
    let outcome = await repository.importFiles([source], origin: .clipboard, expiresAt: nil)
    XCTAssertEqual(outcome.successes.count, 1)

    let cleanup = try await repository.cleanup()

    XCTAssertEqual(cleanup.physicalUsageBytes, 6)
    XCTAssertEqual(cleanup.quotaBytes, 0)
    XCTAssertTrue(cleanup.requiresManualCleanup)
    let snapshot = await repository.snapshot()
    XCTAssertNotNil(snapshot.first?.trashedAt)
  }

  func testClipboardStackInheritsClipboardRetention() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let firstExpiration = now.addingTimeInterval(3_600)
    let secondExpiration = now.addingTimeInterval(7_200)
    let first = try await repository.addText(
      "First",
      kind: .text,
      origin: .clipboard,
      expiresAt: firstExpiration
    )
    let second = try await repository.addText(
      "Second",
      kind: .text,
      origin: .clipboard,
      expiresAt: secondExpiration
    )

    let stack = try await repository.stack(ids: [first.id, second.id])

    XCTAssertEqual(stack.origin, .clipboard)
    XCTAssertEqual(stack.expiresAt, firstExpiration)
  }

  func testMixedOriginStackDoesNotExpireAutomatically() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let imported = try await repository.addText(
      "Imported",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )
    let clipboard = try await repository.addText(
      "Clipboard",
      kind: .text,
      origin: .clipboard,
      expiresAt: now.addingTimeInterval(3_600)
    )

    let stack = try await repository.stack(ids: [imported.id, clipboard.id])

    XCTAssertEqual(stack.origin, .imported)
    XCTAssertNil(stack.expiresAt)
  }

  private func configuration(
    root: URL,
    quotaBytes: Int64 = 1_073_741_824,
    now: (@Sendable () -> Date)? = nil,
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter
  ) -> RepositoryConfiguration {
    let defaultNow = self.now
    let configuredNow = now ?? { defaultNow }
    return RepositoryConfiguration(
      rootURL: root,
      deviceID: "test-mac",
      quotaBytes: quotaBytes,
      trashRetention: 604_800,
      now: configuredNow,
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

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedDate: Date

  init(_ date: Date) {
    storedDate = date
  }

  var date: Date {
    get { lock.withLock { storedDate } }
    set { lock.withLock { storedDate = newValue } }
  }
}
