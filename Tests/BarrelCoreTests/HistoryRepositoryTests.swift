import Foundation
import XCTest
@testable import BarrelCore

final class HistoryRepositoryTests: XCTestCase {
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
    HistoryEvent(
      id: UUID(),
      itemID: UUID(),
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

private struct ManifestFixture: Encodable {
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
