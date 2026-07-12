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

  func testOpenHistoryRefreshesBeforeReturningAtRetentionBoundary() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.export(fileName: "Expired.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    XCTAssertEqual(store.historyEvents.count, 1)
    fixture.advance(by: 24 * 60 * 60)

    await store.openHistory()

    XCTAssertEqual(store.viewMode, .history)
    XCTAssertTrue(store.historyEvents.isEmpty)
  }

  func testOpenHistoryChangesViewMode() async throws {
    let store = ShelfStore(
      repository: Fixture.unloadedRepository(),
      indexesSpotlight: false,
      loadOnInit: false
    )

    await store.openHistory()

    XCTAssertEqual(store.viewMode, .history)
  }

  func testOpenHistoryClearsBucketSelection() async throws {
    let fixture = try await Fixture()
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    let item = try XCTUnwrap(store.visibleItems.first)
    store.select(item)
    store.toggleSelection(for: item)

    await store.openHistory()

    XCTAssertNil(store.selectedItemID)
    XCTAssertTrue(store.selectedIDs.isEmpty)
  }

  func testHistoryRefreshAndUndoKeepBucketSelectionEmpty() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "History.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    await store.openHistory()

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

  func testRemoteTombstoneUndoRefreshDisplaysLiveTemporaryOverlayWithoutChangingSync() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "Overlay.txt")
    let tombstone = try await fixture.applyRemoteTombstone(after: export)
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)

    await store.performUndo(export)

    let displayed = try XCTUnwrap(store.items.first)
    XCTAssertEqual(displayed.id, export.itemID)
    XCTAssertNil(displayed.deletedAt)
    XCTAssertEqual(displayed.fileName, "Source.txt")
    XCTAssertEqual(store.liveItemCount, 1)
    XCTAssertEqual(store.visibleItems.map(\.id), [export.itemID])
    let displayedURL = try XCTUnwrap(store.fileURL(for: displayed))
    XCTAssertTrue(FileManager.default.fileExists(atPath: displayedURL.path))
    XCTAssertFalse(store.isCanonicalMutationEligible(displayed))
    store.setPinned(displayed, isPinned: true)
    await Task.yield()
    let sync = try await fixture.repository.syncRecords()
    XCTAssertEqual(sync.map(\.item), [tombstone])
  }

  func testRemoteTombstoneUndoClearsMutationSelectionForLocalOverlay() async throws {
    let fixture = try await Fixture()
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    let item = try XCTUnwrap(store.visibleItems.first)
    store.toggleSelection(for: item)
    let export = try await fixture.export(fileName: "Overlay.txt")
    _ = try await fixture.applyRemoteTombstone(after: export)

    await store.performUndo(export)

    XCTAssertTrue(store.selectedIDs.isEmpty)
  }

  func testRemoteTombstoneUndoOverlayCanBeReexportedThroughStore() async throws {
    let fixture = try await Fixture()
    let export = try await fixture.export(fileName: "Overlay.txt")
    let tombstone = try await fixture.applyRemoteTombstone(after: export)
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.performUndo(export)
    let displayed = try XCTUnwrap(store.items.first)
    let syncBeforeReexport = try await fixture.repository.syncRecords()

    let reexport = try await store.exportForQuickSend(
      itemID: displayed.id,
      to: fixture.destination,
      fileName: "Overlay Again.txt"
    )

    XCTAssertEqual(reexport.fileName, "Overlay Again.txt")
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(reexport.destinationURL)), Data("contents".utf8))
    XCTAssertTrue(store.visibleItems.isEmpty)
    let syncAfterReexport = try await fixture.repository.syncRecords()
    XCTAssertEqual(syncAfterReexport, syncBeforeReexport)
    XCTAssertEqual(syncAfterReexport.map(\.item), [tombstone])

    await store.performUndo(reexport)

    XCTAssertEqual(store.visibleItems.map(\.id), [displayed.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL(for: store.visibleItems[0])).path))
    let syncAfterSecondUndo = try await fixture.repository.syncRecords()
    XCTAssertEqual(syncAfterSecondUndo, syncBeforeReexport)
  }

  func testPublishedPendingExportRefreshesImmediatelyBlocksRetryAndRecoversExactlyOnce() async throws {
    let fault = ExportFaultOnce(.beforeFinalCommit)
    let fixture = try await Fixture(exportFaultInjector: { point in try fault.inject(point) })
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    let item = try XCTUnwrap(store.visibleItems.first)

    do {
      _ = try await store.export(itemID: item.id, to: fixture.destination, fileName: "Pending.txt")
      XCTFail("Expected pending finalization")
    } catch RepositoryError.exportPendingRecovery(_, let phase) {
      XCTAssertEqual(phase, .publishedPendingFinalization)
    }

    XCTAssertTrue(store.visibleItems.isEmpty)
    XCTAssertEqual(
      store.errorMessage,
      "The export was published, but Barrel must finish recording it on the next launch."
    )
    do {
      _ = try await store.export(itemID: item.id, to: fixture.destination, fileName: "Duplicate.txt")
      XCTFail("Expected duplicate retry to be blocked")
    } catch RepositoryError.itemNotFound(item.id) {}
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fixture.destination.appendingPathComponent("Duplicate.txt").path
    ))

    let recovered = try await fixture.recoveredState()
    XCTAssertTrue(recovered.temporary.isEmpty)
    XCTAssertEqual(recovered.history.map(\.itemID), [item.id])
    XCTAssertEqual(Set(recovered.history.map(\.id)).count, 1)
    XCTAssertEqual(
      try Data(contentsOf: fixture.destination.appendingPathComponent("Pending.txt")),
      Data("contents".utf8)
    )
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

  func testResultReturningUndoReportsCommittedCleanupWarning() async throws {
    let manager = UndoCleanupFailureFileManager()
    let fixture = try await Fixture(fileManager: manager)
    let export = try await fixture.export(fileName: "Cleanup Result.txt")
    let store = ShelfStore(repository: fixture.repository, indexesSpotlight: false, loadOnInit: false)
    await store.refresh()
    manager.failUndoCleanup = true

    let outcome = try await store.undoForQuickSend(export)

    XCTAssertTrue(outcome.isCommitted)
    XCTAssertEqual(outcome.warning, "Undo was saved, but its recovery bytes could not be removed.")
    XCTAssertEqual(store.liveItemCount, 1)
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
  let destination: URL
  private let clock = Clock()
  private(set) var undoEventID: UUID?

  init(
    fileManager: FileManager = .default,
    exportFaultInjector: @escaping ExportFaultInjector = { _ in }
  ) async throws {
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
      now: { [clock] in clock.now },
      exportFaultInjector: exportFaultInjector
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

  func applyRemoteTombstone(after export: HistoryEvent) async throws -> ShelfItem {
    let snapshot = await repository.snapshot()
    var tombstone = try XCTUnwrap(snapshot.first)
    tombstone.title = "Deleted Item"
    tombstone.fileName = nil
    tombstone.relativePath = nil
    tombstone.contentHash = nil
    tombstone.deletedAt = export.timestamp.addingTimeInterval(1)
    tombstone.updatedAt = tombstone.deletedAt!
    tombstone.revision += 1
    try await repository.applySyncRecords([SyncRecord(item: tombstone)])
    return tombstone
  }

  func recoveredState() async throws -> (temporary: [ShelfItem], history: [HistoryEvent]) {
    let recovered = ShelfRepository(configuration: RepositoryConfiguration(
      rootURL: root.appendingPathComponent("Repository", isDirectory: true),
      deviceID: "test",
      historyRetention: 24 * 60 * 60,
      now: { [clock] in clock.now }
    ))
    _ = try await recovered.load()
    return (try await recovered.temporarySnapshot(), try await recovered.historySnapshot())
  }

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

private final class ExportFaultOnce: @unchecked Sendable {
  private let point: ExportFaultPoint
  private var hasFailed = false

  init(_ point: ExportFaultPoint) { self.point = point }

  func inject(_ candidate: ExportFaultPoint) throws {
    if candidate == point, !hasFailed {
      hasFailed = true
      throw StoreHistoryTestError.injectedFailure
    }
  }
}

private enum StoreHistoryTestError: Error { case injectedFailure }
