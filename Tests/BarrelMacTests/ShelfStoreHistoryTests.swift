import BarrelCore
import Combine
import XCTest
@testable import BarrelMac

@MainActor
final class ShelfStoreHistoryTests: XCTestCase {
  func testLaunchRefreshLoadsTemporaryItemsAndNewestFirstHistory() async throws {
    let fixture = try await Fixture()
    let older = try await fixture.export(fileName: "Older.txt")
    fixture.advance(by: 1)
    try await fixture.repository.undo(historyEventID: older.id)
    fixture.advance(by: 1)
    let newer = try await fixture.export(fileName: "Newer.txt")

    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: true)
    await fulfillment(of: [published(store.$historyEvents) { $0.count == 3 }], timeout: 2)

    XCTAssertEqual(store.historyEvents.map(\.id), [newer.id, fixture.undoEventID, older.id])
    XCTAssertEqual(store.liveItemCount, 0)
    XCTAssertTrue(store.visibleItems.isEmpty)
  }

  func testOpenHistoryChangesViewMode() throws {
    let store = ShelfStore(
      repository: Fixture.unloadedRepository(),
      indexesSpotlight: false,
      loadOnInit: false
    )

    store.openHistory()

    XCTAssertEqual(store.viewMode, .history)
  }

  func testOpenHistoryClearsBucketSelection() async throws {
    let fixture = try await Fixture()
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    let item = try XCTUnwrap(store.visibleItems.first)
    store.select(item)
    store.toggleSelection(for: item)

    store.openHistory()

    XCTAssertNil(store.selectedItemID)
    XCTAssertTrue(store.selectedIDs.isEmpty)
  }

  func testHistoryRefreshAndUndoKeepBucketSelectionEmpty() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "History.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    store.openHistory()

    await store.refresh()

    XCTAssertNil(store.selectedItemID)
    XCTAssertTrue(store.selectedIDs.isEmpty)

    fixture.advance(by: 1)
    await store.performUndo(export)

    XCTAssertNil(store.selectedItemID)
    XCTAssertTrue(store.selectedIDs.isEmpty)
  }

  func testRefreshPrunesHistoryAfterTwentyFourHours() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.export(fileName: "Expired.txt")
    fixture.advance(by: 24 * 60 * 60)
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)

    await store.refresh()

    XCTAssertTrue(store.historyEvents.isEmpty)
    XCTAssertEqual(store.liveItemCount, 0)
  }

  func testSuccessfulUndoRefreshesTemporaryItemsAndHistory() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "Undo.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()

    await store.performUndo(export)

    XCTAssertEqual(store.liveItemCount, 1)
    XCTAssertEqual(store.visibleItems.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: export.destinationURL!.path))
  }

  func testCleanupFailedUndoRefreshesCommittedStateAndShowsWarning() async throws {
    let manager = UndoCleanupFailureFileManager()
    let fixture = try await Fixture(fileManager: manager)
    let export = try await fixture.export(fileName: "Cleanup.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    manager.failUndoCleanup = true
    fixture.advance(by: 1)

    await store.performUndo(export)

    XCTAssertEqual(store.liveItemCount, 1)
    XCTAssertEqual(store.visibleItems.map(\.id), [export.itemID])
    XCTAssertEqual(store.historyEvents.first?.kind, .undo)
    XCTAssertEqual(store.historyEvents.first?.reversedEventID, export.id)
    XCTAssertEqual(
      store.historyEvents.first(where: { $0.id == export.id })?.reversedByEventID,
      store.historyEvents.first?.id
    )
    XCTAssertEqual(store.errorMessage, "Undo was saved, but its recovery bytes could not be removed.")
  }

  func testUndoConflictMessagesAreSpecific() throws {
    let url = URL(fileURLWithPath: "/tmp/Export.txt")
    let recovery = URL(fileURLWithPath: "/tmp/Recovery.txt")
    let cases: [(RepositoryError, String)] = [
      (.undoIneligible(UUID()), "This export is no longer eligible for Undo."),
      (.undoTargetMissing(url), "The exported file is missing."),
      (.undoTargetChanged(url), "The exported file has changed."),
      (.undoTargetInaccessible(url), "The exported file is inaccessible."),
      (.undoTargetNotRegularFile(url), "The export destination is no longer a regular file."),
      (
        .undoRollbackFailed(destination: url, recovery: recovery),
        "Undo could not restore the exported file after the shelf update failed. Recovery bytes were preserved."
      ),
      (
        .undoCleanupFailed(recovery: recovery),
        "Undo was saved, but its recovery bytes could not be removed."
      )
    ]

    for (error, expected) in cases {
      XCTAssertEqual(ShelfStore.undoMessage(for: error), expected)
    }
  }

  func testFailedUndoDoesNotMutateStoreState() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "Missing.txt")
    try FileManager.default.removeItem(at: export.destinationURL!)
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    let originalItems = store.items
    let originalHistory = store.historyEvents
    await store.performUndo(export)

    XCTAssertEqual(store.errorMessage, "The exported file is missing.")
    XCTAssertEqual(store.items, originalItems)
    XCTAssertEqual(store.historyEvents, originalHistory)
  }

  private func published<Value>(
    _ publisher: Published<Value>.Publisher,
    where predicate: @escaping (Value) -> Bool
  ) -> XCTestExpectation {
    let expectation = expectation(description: "Published value matched")
    var cancellable: AnyCancellable?
    cancellable = publisher.sink { value in
      guard predicate(value) else { return }
      expectation.fulfill()
      cancellable?.cancel()
    }
    addTeardownBlock { cancellable?.cancel() }
    return expectation
  }
}

private final class Fixture: @unchecked Sendable {
  let repository: ShelfRepository
  private let root: URL
  private let source: URL
  private let destination: URL
  private let clock = Clock()
  private(set) var undoEventID: UUID?

  init(fileManager: FileManager = .default) async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShelfStoreHistoryTests-\(UUID().uuidString)", isDirectory: true)
    source = root.appendingPathComponent("Source.txt")
    destination = root.appendingPathComponent("Finder", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("contents".utf8).write(to: source)
    repository = ShelfRepository(configuration: RepositoryConfiguration(
      rootURL: root.appendingPathComponent("Repository", isDirectory: true),
      deviceID: "test",
      historyRetention: 24 * 60 * 60,
      now: { [clock] in clock.now }
    ), fileManager: fileManager)
    _ = try await repository.load()
    _ = await repository.importFiles([source], origin: .imported, expiresAt: nil)
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  func export(fileName: String) async throws -> HistoryEvent {
    let items = try await repository.temporarySnapshot()
    let item = try XCTUnwrap(items.first)
    let event = try await repository.export(itemID: item.id, to: destination, fileName: fileName)
    let history = try await repository.historySnapshot()
    undoEventID = history.first(where: { $0.kind == .undo })?.id
    return event
  }

  func advance(by interval: TimeInterval) { clock.now.addTimeInterval(interval) }

  static func unloadedRepository() -> ShelfRepository {
    ShelfRepository(configuration: RepositoryConfiguration(
      rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("ShelfStoreHistoryTests-Unloaded-\(UUID().uuidString)"),
      deviceID: "test"
    ))
  }
}

private final class UndoCleanupFailureFileManager: FileManager, @unchecked Sendable {
  var failUndoCleanup = false

  override func removeItem(at URL: URL) throws {
    if failUndoCleanup, URL.lastPathComponent.hasPrefix(".barrel-undo-") {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: URL)
  }
}

private final class Clock: @unchecked Sendable {
  var now = Date(timeIntervalSince1970: 1_700_000_000)
}
