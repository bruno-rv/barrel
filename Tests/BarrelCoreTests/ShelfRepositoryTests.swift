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
    XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("shelf.json").path))

    let recovered = try await repository.addText(
      "Recovered",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )
    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.map(\.id), [recovered.id])
    XCTAssertEqual(snapshot.map(\.title), ["Recovered"])
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
    XCTAssertEqual(ShelfFilter.all.filter(snapshot, query: "").map(\.id), [second.id])
    XCTAssertNotNil(snapshot.first(where: { $0.id == first.id })?.deletedAt)
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
    XCTAssertEqual(ShelfFilter.trash.filter(snapshot, query: "").map(\.id), [second.id])
    XCTAssertNotNil(snapshot.first(where: { $0.id == first.id })?.deletedAt)
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

  func testCleanupKeepsExpiredClipboardStackWhenAChildIsPinned() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root, quotaBytes: 0))
    let expiration = now.addingTimeInterval(-1)
    let pinned = try await repository.addText(
      "Pinned child",
      kind: .text,
      origin: .clipboard,
      expiresAt: expiration
    )
    let unpinned = try await repository.addText(
      "Unpinned child",
      kind: .text,
      origin: .clipboard,
      expiresAt: expiration
    )
    try await repository.setPinned(id: pinned.id, isPinned: true)
    let stack = try await repository.stack(ids: [pinned.id, unpinned.id])

    try await repository.cleanup()

    let snapshot = await repository.snapshot()
    XCTAssertNil(snapshot.first(where: { $0.id == stack.id })?.trashedAt)
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

  func testApplySyncRecordsCopiesRemoteAssetIntoManagedStorage() async throws {
    let root = try makeRoot()
    let remoteAsset = try makeSource(named: "remote.txt", contents: "remote bytes")
    let remoteItem = ShelfItem(
      id: UUID(),
      title: "Remote",
      kind: .file,
      createdAt: now,
      updatedAt: now,
      fileName: "remote.txt",
      relativePath: "Items/another-mac/remote.txt",
      origin: .sync,
      revision: 2,
      modifiedByDeviceID: "remote-mac"
    )
    let repository = ShelfRepository(configuration: configuration(root: root))

    try await repository.applySyncRecords([SyncRecord(item: remoteItem, assetURL: remoteAsset)])

    let records = try await repository.syncRecords()
    let record = try XCTUnwrap(records.first)
    let managedURL = try XCTUnwrap(record.assetURL)
    XCTAssertEqual(record.item.id, remoteItem.id)
    XCTAssertEqual(try Data(contentsOf: managedURL), Data("remote bytes".utf8))
    XCTAssertTrue(managedURL.path.hasPrefix(root.appendingPathComponent("Items").path + "/"))
  }

  func testApplySyncRecordsRejectsMissingAdvertisedAssetWithoutChangingLocalItem() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "local.txt", contents: "last local bytes")
    let repository = ShelfRepository(configuration: configuration(root: root))
    let outcome = await repository.importFiles([source], origin: .imported, expiresAt: nil)
    let local = try XCTUnwrap(outcome.successes.first)
    let localPath = try XCTUnwrap(local.relativePath)
    let resolvedLocalURL = await repository.fileURL(for: local)
    let localURL = try XCTUnwrap(resolvedLocalURL)
    var remote = local
    remote.title = "Newer remote metadata"
    remote.fileName = "remote.txt"
    remote.relativePath = "Items/remote/remote.txt"
    remote.updatedAt = local.updatedAt.addingTimeInterval(1)
    remote.revision = local.revision + 1
    remote.modifiedByDeviceID = "remote-mac"

    do {
      try await repository.applySyncRecords([
        SyncRecord(item: remote, assetsByRelativePath: [:])
      ])
      XCTFail("Expected the missing advertised asset to reject the sync apply")
    } catch RepositoryError.missingSyncAsset(let path) {
      XCTAssertEqual(path, remote.relativePath)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let snapshot = await repository.snapshot()
    let unchanged = try XCTUnwrap(snapshot.first(where: { $0.id == local.id }))
    XCTAssertEqual(unchanged.title, local.title)
    XCTAssertEqual(unchanged.relativePath, localPath)
    XCTAssertEqual(try Data(contentsOf: localURL), Data("last local bytes".utf8))
  }

  func testApplySyncRecordsAllowsMetadataOnlyItemAndAlreadyPresentAssetPath() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "local.txt", contents: "available locally")
    let repository = ShelfRepository(configuration: configuration(root: root))
    let outcome = await repository.importFiles([source], origin: .imported, expiresAt: nil)
    let local = try XCTUnwrap(outcome.successes.first)
    var remote = local
    remote.title = "Remote rename"
    remote.updatedAt = local.updatedAt.addingTimeInterval(1)
    remote.revision = local.revision + 1
    remote.modifiedByDeviceID = "remote-mac"
    let metadataOnly = ShelfItem(
      title: "Remote note",
      kind: .text,
      createdAt: now,
      updatedAt: now,
      text: "No asset required",
      origin: .sync,
      revision: 1,
      modifiedByDeviceID: "remote-mac"
    )

    try await repository.applySyncRecords([
      SyncRecord(item: remote, assetsByRelativePath: [:]),
      SyncRecord(item: metadataOnly, assetsByRelativePath: [:])
    ])

    let snapshot = await repository.snapshot()
    XCTAssertEqual(snapshot.first(where: { $0.id == local.id })?.title, "Remote rename")
    XCTAssertEqual(snapshot.first(where: { $0.id == local.id })?.relativePath, local.relativePath)
    XCTAssertEqual(snapshot.first(where: { $0.id == metadataOnly.id })?.text, "No asset required")
  }

  func testColdMutationLoadsExistingManifestBeforeCommit() async throws {
    let root = try makeRoot()
    let firstRepository = ShelfRepository(configuration: configuration(root: root))
    let existing = try await firstRepository.addText(
      "Existing",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )
    let coldRepository = ShelfRepository(configuration: configuration(root: root))

    let added = try await coldRepository.addText(
      "Added from intent",
      kind: .text,
      origin: .shortcut,
      expiresAt: nil
    )

    let snapshot = await coldRepository.snapshot()
    XCTAssertEqual(Set(snapshot.map(\.id)), Set([existing.id, added.id]))
  }

  func testApplySyncRecordsMergesWithChangesMadeAfterNetworkSnapshot() async throws {
    let root = try makeRoot()
    let repository = ShelfRepository(configuration: configuration(root: root))
    let original = try await repository.addText(
      "Original",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )
    let staleNetworkResult = try await repository.syncRecords()
    let concurrent = try await repository.addText(
      "Concurrent import",
      kind: .text,
      origin: .imported,
      expiresAt: nil
    )
    try await repository.rename(id: original.id, title: "Renamed while syncing")

    try await repository.applySyncRecords(staleNetworkResult)

    let snapshot = await repository.snapshot()
    XCTAssertEqual(Set(snapshot.map(\.id)), Set([original.id, concurrent.id]))
    XCTAssertEqual(snapshot.first(where: { $0.id == original.id })?.title, "Renamed while syncing")
  }

  func testPermanentDeletionCreatesTombstoneAndPreventsRemoteResurrection() async throws {
    let root = try makeRoot()
    let source = try makeSource(named: "delete.txt", contents: "delete me")
    let clock = TestClock(now)
    let repository = ShelfRepository(configuration: configuration(root: root, now: { clock.date }))
    let imported = await repository.importFiles([source], origin: .imported, expiresAt: nil)
    let item = try XCTUnwrap(imported.successes.first)
    let resolvedURL = await repository.fileURL(for: item)
    let managedURL = try XCTUnwrap(resolvedURL)
    try await repository.trash(ids: [item.id])
    clock.date = now.addingTimeInterval(60)

    try await repository.emptyTrash()

    var snapshot = await repository.snapshot()
    let tombstone = try XCTUnwrap(snapshot.first(where: { $0.id == item.id }))
    XCTAssertEqual(tombstone.deletedAt, clock.date)
    XCTAssertFalse(fileManager.fileExists(atPath: managedURL.path))
    XCTAssertTrue(ShelfFilter.all.filter(snapshot, query: "").isEmpty)
    XCTAssertTrue(ShelfFilter.trash.filter(snapshot, query: "").isEmpty)

    try await repository.applySyncRecords([SyncRecord(item: item)])

    snapshot = await repository.snapshot()
    XCTAssertNotNil(snapshot.first(where: { $0.id == item.id })?.deletedAt)
  }

  func testPermanentDeletionTombstoneScrubsPrivateContent() async throws {
    let root = try makeRoot()
    let asset = try makeSource(named: "private.txt", contents: "private bytes")
    let remotePath = "Items/remote/private.txt"
    let item = ShelfItem(
      id: UUID(),
      title: "Private project codename",
      kind: .stack,
      createdAt: now,
      updatedAt: now,
      fileName: "private.txt",
      relativePath: remotePath,
      text: "Sensitive copied text",
      children: [ShelfItem(title: "Secret child", kind: .text, text: "Child secret")],
      origin: .sync,
      contentHash: "sensitive-hash",
      revision: 7,
      modifiedByDeviceID: "remote-mac"
    )
    let repository = ShelfRepository(configuration: configuration(root: root))
    try await repository.applySyncRecords([
      SyncRecord(item: item, assetsByRelativePath: [remotePath: asset])
    ])
    try await repository.trash(ids: [item.id])

    try await repository.deletePermanently(ids: [item.id])

    let snapshot = await repository.snapshot()
    let tombstone = try XCTUnwrap(snapshot.first(where: { $0.id == item.id }))
    XCTAssertEqual(tombstone.id, item.id)
    XCTAssertEqual(tombstone.title, "Deleted Item")
    XCTAssertNil(tombstone.text)
    XCTAssertNil(tombstone.fileName)
    XCTAssertNil(tombstone.relativePath)
    XCTAssertNil(tombstone.contentHash)
    XCTAssertTrue(tombstone.children.isEmpty)
    XCTAssertNotNil(tombstone.deletedAt)
    XCTAssertGreaterThan(tombstone.revision, item.revision)
    XCTAssertEqual(tombstone.modifiedByDeviceID, "test-mac")
  }

  func testNestedStackAssetsRoundTripByRelativePath() async throws {
    let root = try makeRoot()
    let firstAsset = try makeSource(named: "first.txt", contents: "first bytes")
    let secondAsset = try makeSource(named: "second.txt", contents: "second bytes")
    let firstPath = "Items/remote-first/first.txt"
    let secondPath = "Items/remote-second/second.txt"
    let first = ShelfItem(
      id: UUID(),
      title: "First",
      kind: .file,
      createdAt: now,
      updatedAt: now,
      fileName: "first.txt",
      relativePath: firstPath,
      revision: 1,
      modifiedByDeviceID: "remote"
    )
    let second = ShelfItem(
      id: UUID(),
      title: "Second",
      kind: .file,
      createdAt: now,
      updatedAt: now,
      fileName: "second.txt",
      relativePath: secondPath,
      revision: 1,
      modifiedByDeviceID: "remote"
    )
    let stack = ShelfItem(
      id: UUID(),
      title: "Stack",
      kind: .stack,
      createdAt: now,
      updatedAt: now,
      children: [first, second],
      revision: 1,
      modifiedByDeviceID: "remote"
    )
    let repository = ShelfRepository(configuration: configuration(root: root))

    try await repository.applySyncRecords([
      SyncRecord(
        item: stack,
        assetsByRelativePath: [firstPath: firstAsset, secondPath: secondAsset]
      )
    ])

    let records = try await repository.syncRecords()
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(record.assetsByRelativePath.count, 2)
    XCTAssertEqual(
      Set(try record.assetsByRelativePath.values.map { try String(contentsOf: $0, encoding: .utf8) }),
      Set(["first bytes", "second bytes"])
    )
  }

  func testFailedSyncApplyPreservesPreexistingItemDirectory() async throws {
    let root = try makeRoot()
    let failure = ManifestFailureSwitch()
    let repository = ShelfRepository(
      configuration: configuration(
        root: root,
        manifestWriter: { data, destination in
          if failure.shouldFail { throw TestError.writeFailed }
          try RepositoryConfiguration.defaultManifestWriter(data, destination)
        }
      )
    )
    _ = try await repository.load()
    let itemID = UUID()
    let existingDirectory = root
      .appendingPathComponent("Items", isDirectory: true)
      .appendingPathComponent(itemID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
    let sentinel = existingDirectory.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    let asset = try makeSource(named: "incoming.txt", contents: "incoming")
    let remotePath = "Items/remote/incoming.txt"
    let item = ShelfItem(
      id: itemID,
      title: "Incoming",
      kind: .file,
      createdAt: now,
      updatedAt: now,
      fileName: "incoming.txt",
      relativePath: remotePath,
      revision: 1,
      modifiedByDeviceID: "remote"
    )
    failure.shouldFail = true

    do {
      try await repository.applySyncRecords([
        SyncRecord(item: item, assetsByRelativePath: [remotePath: asset])
      ])
      XCTFail("Expected manifest write failure")
    } catch TestError.writeFailed {
      // Expected.
    }

    XCTAssertTrue(fileManager.fileExists(atPath: sentinel.path))
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
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

private final class ManifestFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var storedShouldFail = false

  var shouldFail: Bool {
    get { lock.withLock { storedShouldFail } }
    set { lock.withLock { storedShouldFail = newValue } }
  }
}
