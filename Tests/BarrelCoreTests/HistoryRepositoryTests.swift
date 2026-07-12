import Foundation
import XCTest
@testable import BarrelCore

final class HistoryRepositoryTests: XCTestCase {
  func testExportSelectsCollisionSafeNamePersistsLocalStateAndPreservesSyncRecords() async throws {
    let fixture = try ExportFixture(fileName: "report.pdf", contents: "report bytes")
    defer { fixture.remove() }
    try Data("occupied".utf8).write(to: fixture.destination.appendingPathComponent("report.pdf"))
    try Data("occupied".utf8).write(to: fixture.destination.appendingPathComponent("report 2.pdf"))
    let before = try await fixture.repository.syncRecords()

    let event = try await fixture.repository.export(itemID: fixture.item.id, to: fixture.destination)

    let exportedURL = fixture.destination.appendingPathComponent("report 3.pdf")
    XCTAssertEqual(event.destinationURL, exportedURL)
    XCTAssertEqual(event.fileName, "report 3.pdf")
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
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter
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
    repository = ShelfRepository(configuration: configuration)
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
