import Foundation
import XCTest
@testable import BarrelCore

final class HistoryRepositoryTests: XCTestCase {
  func testExportPreservesExactNamePersistsLocalStateAndPreservesSyncRecords() async throws {
    let fixture = try ExportFixture(fileName: "report.pdf", contents: "report bytes")
    defer { fixture.remove() }
    let before = try await fixture.repository.syncRecords()

    let event = try await fixture.repository.export(
      itemID: fixture.item.id,
      to: fixture.destination,
      fileName: "Promised Report.pdf"
    )

    let exportedURL = fixture.destination.appendingPathComponent("Promised Report.pdf")
    XCTAssertEqual(event.destinationURL, exportedURL)
    XCTAssertEqual(event.fileName, "Promised Report.pdf")
    XCTAssertEqual(try Data(contentsOf: exportedURL), Data("report bytes".utf8))
    let temporary = try await fixture.repository.temporarySnapshot()
    let after = try await fixture.repository.syncRecords()
    XCTAssertEqual(temporary, [])
    XCTAssertEqual(after, before)
    let reloaded = ShelfRepository(configuration: fixture.configuration)
    let reloadedTemporary = try await reloaded.temporarySnapshot()
    let reloadedHistory = try await reloaded.historySnapshot()
    XCTAssertEqual(reloadedTemporary, [])
    XCTAssertEqual(reloadedHistory.map(\.id), [event.id])
  }

  func testExportFailsWithoutOverwritingOrSuffixingWhenPromisedNameExists() async throws {
    let fixture = try ExportFixture(fileName: "report.pdf", contents: "report bytes")
    defer { fixture.remove() }
    let promisedURL = fixture.destination.appendingPathComponent("report.pdf")
    try Data("occupied".utf8).write(to: promisedURL)

    do {
      _ = try await fixture.repository.export(
        itemID: fixture.item.id,
        to: fixture.destination,
        fileName: "report.pdf"
      )
      XCTFail("Expected collision failure")
    } catch RepositoryError.exportDestinationExists(let url) {
      XCTAssertEqual(url, promisedURL)
    }

    XCTAssertEqual(try Data(contentsOf: promisedURL), Data("occupied".utf8))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fixture.destination.appendingPathComponent("report 2.pdf").path
    ))
    let temporary = try await fixture.repository.temporarySnapshot()
    let history = try await fixture.repository.historySnapshot()
    XCTAssertEqual(temporary.map(\.id), [fixture.item.id])
    XCTAssertEqual(history, [])
  }

  func testExportManifestFailureRemovesCopyAndKeepsItemTemporary() async throws {
    let failure = HistoryManifestFailureSwitch()
    let fixture = try ExportFixture(
      fileName: "report.pdf",
      contents: "report bytes",
      manifestWriter: { data, destination in
        if failure.shouldFail { throw HistoryTestError.writeFailed }
        try RepositoryConfiguration.defaultManifestWriter(data, destination)
      }
    )
    defer { fixture.remove() }
    _ = try await fixture.repository.load()
    failure.shouldFail = true

    do {
      _ = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
      XCTFail("Expected manifest failure")
    } catch HistoryTestError.writeFailed {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("report.pdf").path))
    failure.shouldFail = false
    let temporary = try await fixture.repository.temporarySnapshot()
    XCTAssertEqual(temporary.map(\.id), [fixture.item.id])
  }

  func testExportOfDeduplicatedItemKeepsManagedFileForLiveDuplicate() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HistoryRepositoryTests-\(UUID())", isDirectory: true)
    let destination = manager.temporaryDirectory.appendingPathComponent("HistoryExports-\(UUID())", isDirectory: true)
    let sourceDirectory = manager.temporaryDirectory.appendingPathComponent("HistorySource-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    try manager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer {
      try? manager.removeItem(at: root)
      try? manager.removeItem(at: destination)
      try? manager.removeItem(at: sourceDirectory)
    }
    let firstSource = sourceDirectory.appendingPathComponent("first.txt")
    let secondSource = sourceDirectory.appendingPathComponent("second.txt")
    try Data("shared".utf8).write(to: firstSource)
    try Data("shared".utf8).write(to: secondSource)
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(rootURL: root, deviceID: "test-mac")
    )
    let outcome = await repository.importFiles([firstSource, secondSource], origin: .imported, expiresAt: nil)
    let first = try XCTUnwrap(outcome.successes.first)
    let resolvedSharedURL = await repository.fileURL(for: first)
    let sharedURL = try XCTUnwrap(resolvedSharedURL)

    _ = try await repository.export(itemID: first.id, to: destination)

    XCTAssertTrue(manager.fileExists(atPath: sharedURL.path))
    let temporary = try await repository.temporarySnapshot()
    XCTAssertEqual(temporary.map(\.id), [try XCTUnwrap(outcome.successes.last).id])
  }

  func testUndoDeletesVerifiedExportRestoresTemporaryItemAndLinksEvents() async throws {
    let fixture = try ExportFixture(fileName: "report.pdf", contents: "report bytes")
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)

    let undo = try await fixture.repository.undo(historyEventID: export.id)

    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
    let temporary = try await fixture.repository.temporarySnapshot()
    XCTAssertEqual(temporary.map(\.id), [fixture.item.id])
    XCTAssertEqual(undo.kind, .undo)
    XCTAssertEqual(undo.reversedEventID, export.id)
    let history = try await fixture.repository.historySnapshot()
    XCTAssertEqual(history.first(where: { $0.id == export.id })?.reversedByEventID, undo.id)
  }

  func testUndoRejectsChangedAndNonlatestExports() async throws {
    let fixture = try ExportFixture(fileName: "report.pdf", contents: "report bytes")
    defer { fixture.remove() }
    let first = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    try await fixture.repository.undo(historyEventID: first.id)
    let second = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    let url = try XCTUnwrap(second.destinationURL)
    try Data("changed".utf8).write(to: url)

    do {
      _ = try await fixture.repository.undo(historyEventID: first.id)
      XCTFail("Expected old event to be ineligible")
    } catch RepositoryError.undoIneligible(first.id) {}
    do {
      _ = try await fixture.repository.undo(historyEventID: second.id)
      XCTFail("Expected changed target")
    } catch RepositoryError.undoTargetChanged(let changedURL) {
      XCTAssertEqual(changedURL.standardizedFileURL.path, url.standardizedFileURL.path)
    }
  }

  func testUndoRejectsMissingAndNonregularTargets() async throws {
    let missingFixture = try ExportFixture(fileName: "missing.pdf", contents: "bytes")
    defer { missingFixture.remove() }
    let missing = try await missingFixture.repository.export(
      itemID: missingFixture.item.id,
      to: missingFixture.destination
    )
    let missingURL = try XCTUnwrap(missing.destinationURL)
    try FileManager.default.removeItem(at: missingURL)
    do {
      _ = try await missingFixture.repository.undo(historyEventID: missing.id)
      XCTFail("Expected missing target")
    } catch RepositoryError.undoTargetMissing(let url) {
      XCTAssertEqual(url.standardizedFileURL.path, missingURL.standardizedFileURL.path)
    }

    let directoryFixture = try ExportFixture(fileName: "directory.pdf", contents: "bytes")
    defer { directoryFixture.remove() }
    let directory = try await directoryFixture.repository.export(
      itemID: directoryFixture.item.id,
      to: directoryFixture.destination
    )
    let directoryURL = try XCTUnwrap(directory.destinationURL)
    try FileManager.default.removeItem(at: directoryURL)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    do {
      _ = try await directoryFixture.repository.undo(historyEventID: directory.id)
      XCTFail("Expected nonregular target")
    } catch RepositoryError.undoTargetNotRegularFile(let url) {
      XCTAssertEqual(url.standardizedFileURL.path, directoryURL.standardizedFileURL.path)
    }
  }

  func testUndoManifestFailureRestoresDestination() async throws {
    let failure = HistoryManifestFailureSwitch()
    let fixture = try ExportFixture(
      fileName: "report.pdf",
      contents: "report bytes",
      manifestWriter: { data, destination in
        if failure.shouldFail { throw HistoryTestError.writeFailed }
        try RepositoryConfiguration.defaultManifestWriter(data, destination)
      }
    )
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    failure.shouldFail = true

    do {
      _ = try await fixture.repository.undo(historyEventID: export.id)
      XCTFail("Expected manifest failure")
    } catch HistoryTestError.writeFailed {}

    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(export.destinationURL)), Data("report bytes".utf8))
  }

  func testUndoRejectsExpiredEventWithoutMutatingManifestOrManagedFile() async throws {
    let fixture = try ExportFixture(fileName: "expired.pdf", contents: "bytes")
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    let manifestURL = fixture.root.appendingPathComponent("shelf.json")
    let resolvedManagedURL = await fixture.repository.fileURL(for: fixture.item)
    let managedURL = try XCTUnwrap(resolvedManagedURL)

    let clock = TestHistoryClock(export.timestamp.addingTimeInterval(86_399))
    let expiredRepository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: fixture.root,
        deviceID: "test-mac",
        now: { clock.now }
      )
    )
    _ = try await expiredRepository.load()
    let before = try Data(contentsOf: manifestURL)
    clock.now = export.timestamp.addingTimeInterval(86_400)
    do {
      _ = try await expiredRepository.undo(historyEventID: export.id)
      XCTFail("Expected expired event to be ineligible")
    } catch RepositoryError.undoIneligible(export.id) {}

    XCTAssertEqual(try Data(contentsOf: manifestURL), before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
  }

  func testUndoRejectsBookmarkResolvedPathMismatchBeforeFileIO() async throws {
    let fixture = try ExportFixture(fileName: "recorded.pdf", contents: "bytes")
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    let recordedURL = try XCTUnwrap(export.destinationURL)
    let otherURL = fixture.destination.appendingPathComponent("other.pdf")
    try Data("bytes".utf8).write(to: otherURL)
    let bookmark = try otherURL.bookmarkData(options: .withSecurityScope)
    var altered = export
    altered.destinationBookmark = bookmark
    let manifestURL = fixture.root.appendingPathComponent("shelf.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ManifestFixture(items: [fixture.item], exportedItemIDs: [fixture.item.id], history: [altered]))
      .write(to: manifestURL, options: .atomic)
    let repository = ShelfRepository(configuration: fixture.configuration)

    do {
      _ = try await repository.undo(historyEventID: export.id)
      XCTFail("Expected bookmark/path mismatch")
    } catch RepositoryError.undoTargetChanged(let url) {
      XCTAssertEqual(url.standardizedFileURL.path, recordedURL.standardizedFileURL.path)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: recordedURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: otherURL.path))
  }

  func testUndoCommitRestoreFailureReportsRecoveryPath() async throws {
    let failure = HistoryManifestFailureSwitch()
    let manager = UndoFailureFileManager()
    let fixture = try ExportFixture(
      fileName: "restore.pdf",
      contents: "bytes",
      manifestWriter: { data, destination in
        if failure.shouldFail { throw HistoryTestError.writeFailed }
        try RepositoryConfiguration.defaultManifestWriter(data, destination)
      },
      fileManager: manager
    )
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    failure.shouldFail = true
    manager.failRestore = true

    do {
      _ = try await fixture.repository.undo(historyEventID: export.id)
      XCTFail("Expected rollback failure")
    } catch RepositoryError.undoRollbackFailed(let destination, let recovery) {
      XCTAssertEqual(
        destination.resolvingSymlinksInPath().path,
        try XCTUnwrap(export.destinationURL).resolvingSymlinksInPath().path
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
  }

  func testUndoRejectsDeterministicallyInaccessibleTargetWithoutMutation() async throws {
    let manager = UndoFailureFileManager()
    let fixture = try ExportFixture(fileName: "inaccessible.pdf", contents: "bytes", fileManager: manager)
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    manager.failStage = true

    do {
      _ = try await fixture.repository.undo(historyEventID: export.id)
      XCTFail("Expected inaccessible target")
    } catch RepositoryError.undoTargetInaccessible(let url) {
      XCTAssertEqual(url.resolvingSymlinksInPath().path, try XCTUnwrap(export.destinationURL).resolvingSymlinksInPath().path)
    }

    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
    let history = try await fixture.repository.historySnapshot()
    XCTAssertEqual(history.count, 1)
  }

  func testUndoCleanupFailureReportsPreservedRecoveryPath() async throws {
    let manager = UndoFailureFileManager()
    let fixture = try ExportFixture(fileName: "cleanup.pdf", contents: "bytes", fileManager: manager)
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    manager.failUndoCleanup = true

    do {
      _ = try await fixture.repository.undo(historyEventID: export.id)
      XCTFail("Expected cleanup failure")
    } catch RepositoryError.undoCleanupFailed(let recovery) {
      XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
      XCTAssertEqual(try Data(contentsOf: recovery), Data("bytes".utf8))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
    let temporary = try await fixture.repository.temporarySnapshot()
    XCTAssertEqual(temporary.map(\.id), [fixture.item.id])
  }

  func testUndoUsesLatestUnreversedExportRatherThanLatestExport() async throws {
    let fixture = try ExportFixture(fileName: "ordering.pdf", contents: "bytes")
    defer { fixture.remove() }
    let older = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    let newerID = UUID()
    let undoID = UUID()
    let newer = HistoryEvent(
      id: newerID,
      itemID: older.itemID,
      kind: .export,
      sourceName: older.sourceName,
      destinationName: older.destinationName,
      destinationURL: older.destinationURL,
      destinationBookmark: older.destinationBookmark,
      fileName: older.fileName,
      contentHash: older.contentHash,
      timestamp: older.timestamp.addingTimeInterval(60),
      reversedEventID: nil,
      reversedByEventID: undoID
    )
    let reversed = HistoryEvent(
      id: undoID,
      itemID: older.itemID,
      kind: .undo,
      sourceName: older.destinationName,
      destinationName: "Barrel",
      destinationURL: older.destinationURL,
      destinationBookmark: older.destinationBookmark,
      fileName: older.fileName,
      contentHash: older.contentHash,
      timestamp: older.timestamp.addingTimeInterval(61),
      reversedEventID: newerID,
      reversedByEventID: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ManifestFixture(
      items: [fixture.item],
      exportedItemIDs: [fixture.item.id],
      history: [older, newer, reversed]
    )).write(to: fixture.root.appendingPathComponent("shelf.json"), options: .atomic)
    let repository = ShelfRepository(configuration: fixture.configuration)

    let undo = try await repository.undo(historyEventID: older.id)

    XCTAssertEqual(undo.reversedEventID, older.id)
  }

  func testUndoConflictDoesNotCommitPendingPruning() async throws {
    let fixture = try ExportFixture(fileName: "conflict.pdf", contents: "bytes")
    defer { fixture.remove() }
    let export = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)
    let manifestURL = fixture.root.appendingPathComponent("shelf.json")
    let clock = TestHistoryClock(export.timestamp.addingTimeInterval(86_399))
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: fixture.root,
        deviceID: "test-mac",
        now: { clock.now }
      )
    )
    _ = try await repository.load()
    let before = try Data(contentsOf: manifestURL)
    clock.now = export.timestamp.addingTimeInterval(86_400)

    do {
      _ = try await repository.undo(historyEventID: UUID())
      XCTFail("Expected conflict")
    } catch RepositoryError.undoIneligible {}

    XCTAssertEqual(try Data(contentsOf: manifestURL), before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(export.destinationURL).path))
  }

  func testHistorySnapshotIsNewestFirstAndPrunesAtExactRetentionBoundary() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("HistoryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let older = event(timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    let newer = event(timestamp: older.timestamp.addingTimeInterval(60))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ManifestFixture(items: [], exportedItemIDs: [], history: [older, newer]))
      .write(to: root.appendingPathComponent("shelf.json"))
    let clock = TestHistoryClock(older.timestamp.addingTimeInterval(86_399))
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: root,
        deviceID: "test-mac",
        now: { clock.now }
      )
    )

    var snapshot = try await repository.historySnapshot()
    XCTAssertEqual(snapshot.map(\.id), [newer.id, older.id])

    clock.now = older.timestamp.addingTimeInterval(86_400)
    snapshot = try await repository.historySnapshot()
    XCTAssertEqual(snapshot.map(\.id), [newer.id])
  }

  func testLoadPrunesExpiredUnsharedExportDeletesManagedFileAndPersistsEnvelope() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("HistoryRepositoryTests-\(UUID())", isDirectory: true)
    let managedDirectory = root.appendingPathComponent("Items/expired", isDirectory: true)
    try manager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let managedFile = managedDirectory.appendingPathComponent("expired.txt")
    try Data("expired".utf8).write(to: managedFile)
    let item = ShelfItem(title: "Expired", kind: .file, fileName: "expired.txt", relativePath: "Items/expired/expired.txt")
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = event(itemID: item.id, timestamp: timestamp)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(ManifestFixture(items: [item], exportedItemIDs: [item.id], history: [expired]))
      .write(to: root.appendingPathComponent("shelf.json"))
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: root,
        deviceID: "test-mac",
        now: { timestamp.addingTimeInterval(86_400) }
      )
    )

    _ = try await repository.load()

    XCTAssertFalse(manager.fileExists(atPath: managedFile.path))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let persisted = try decoder.decode(
      ManifestFixture.self,
      from: Data(contentsOf: root.appendingPathComponent("shelf.json"))
    )
    XCTAssertEqual(persisted.items, [])
    XCTAssertEqual(persisted.exportedItemIDs, [])
    XCTAssertEqual(persisted.history, [])
  }

  func testExpiringLastExportEventRemovesItemButKeepsSharedManagedFile() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("HistoryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    let managedDirectory = root.appendingPathComponent("Items/shared", isDirectory: true)
    try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let managedFile = managedDirectory.appendingPathComponent("shared.txt")
    try Data("shared".utf8).write(to: managedFile)
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let exported = ShelfItem(
      title: "Exported",
      kind: .file,
      fileName: "shared.txt",
      relativePath: "Items/shared/shared.txt"
    )
    let duplicate = ShelfItem(
      title: "Duplicate",
      kind: .file,
      fileName: "shared.txt",
      relativePath: "Items/shared/shared.txt"
    )
    let exportEvent = HistoryEvent(
      itemID: exported.id,
      kind: .export,
      sourceName: "Barrel",
      destinationName: "Desktop",
      destinationURL: nil,
      destinationBookmark: nil,
      fileName: "shared.txt",
      contentHash: "abc123",
      timestamp: timestamp,
      reversedEventID: nil,
      reversedByEventID: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(
      ManifestFixture(
        items: [exported, duplicate],
        exportedItemIDs: [exported.id],
        history: [exportEvent]
      )
    ).write(to: root.appendingPathComponent("shelf.json"))
    let clock = TestHistoryClock(timestamp.addingTimeInterval(86_399))
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: root,
        deviceID: "test-mac",
        now: { clock.now }
      )
    )
    _ = try await repository.load()

    clock.now = timestamp.addingTimeInterval(86_400)
    let history = try await repository.historySnapshot()
    XCTAssertEqual(history, [])
    let items = await repository.snapshot()
    XCTAssertEqual(items.map(\.id), [duplicate.id])
    XCTAssertTrue(fileManager.fileExists(atPath: managedFile.path))
  }

  private func event(timestamp: Date) -> HistoryEvent {
    event(itemID: UUID(), timestamp: timestamp)
  }

  private func event(itemID: UUID, timestamp: Date) -> HistoryEvent {
    HistoryEvent(
      id: UUID(),
      itemID: itemID,
      kind: .export,
      sourceName: "Barrel",
      destinationName: "Desktop",
      destinationURL: URL(fileURLWithPath: "/tmp/export.txt"),
      destinationBookmark: nil,
      fileName: "export.txt",
      contentHash: "abc123",
      timestamp: timestamp,
      reversedEventID: nil,
      reversedByEventID: nil
    )
  }
}

private struct ExportFixture {
  let root: URL
  let destination: URL
  let configuration: RepositoryConfiguration
  let repository: ShelfRepository
  let item: ShelfItem

  init(
    fileName: String,
    contents: String,
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter,
    fileManager: FileManager = .default
  ) throws {
    let manager = FileManager.default
    root = manager.temporaryDirectory.appendingPathComponent("HistoryRepositoryTests-\(UUID())", isDirectory: true)
    destination = manager.temporaryDirectory.appendingPathComponent("HistoryExports-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = manager.temporaryDirectory.appendingPathComponent("HistorySource-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: source.appendingPathComponent(fileName))
    configuration = RepositoryConfiguration(rootURL: root, deviceID: "test-mac", manifestWriter: manifestWriter)
    repository = ShelfRepository(configuration: configuration, fileManager: fileManager)
    let outcome = try blockingImport(repository: repository, source: source.appendingPathComponent(fileName))
    item = try XCTUnwrap(outcome.successes.first)
    try? manager.removeItem(at: source)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: destination)
  }
}

private func blockingImport(repository: ShelfRepository, source: URL) throws -> ImportOutcome {
  let semaphore = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: ImportOutcome?
  Task {
    result = await repository.importFiles([source], origin: .imported, expiresAt: nil)
    semaphore.signal()
  }
  semaphore.wait()
  return try XCTUnwrap(result)
}

private final class HistoryManifestFailureSwitch: @unchecked Sendable {
  var shouldFail = false
}

private enum HistoryTestError: Error { case writeFailed }

private final class UndoFailureFileManager: FileManager, @unchecked Sendable {
  var failRestore = false
  var failStage = false
  var failUndoCleanup = false

  override func moveItem(at srcURL: URL, to dstURL: URL) throws {
    if failStage, dstURL.lastPathComponent.hasPrefix(".barrel-undo-") {
      throw HistoryTestError.writeFailed
    }
    if failRestore, srcURL.lastPathComponent.hasPrefix(".barrel-undo-") {
      throw HistoryTestError.writeFailed
    }
    try super.moveItem(at: srcURL, to: dstURL)
  }

  override func removeItem(at URL: URL) throws {
    if failUndoCleanup, URL.lastPathComponent.hasPrefix(".barrel-undo-") {
      throw HistoryTestError.writeFailed
    }
    try super.removeItem(at: URL)
  }
}

private struct ManifestFixture: Codable {
  let items: [ShelfItem]
  let exportedItemIDs: Set<UUID>
  let history: [HistoryEvent]
}

private final class TestHistoryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedNow: Date

  init(_ now: Date) {
    storedNow = now
  }

  var now: Date {
    get { lock.withLock { storedNow } }
    set { lock.withLock { storedNow = newValue } }
  }
}
