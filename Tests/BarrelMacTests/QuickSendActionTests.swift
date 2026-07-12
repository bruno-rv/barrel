import BarrelCore
import Foundation
import Testing
@testable import BarrelMac

@MainActor
struct QuickSendActionTests {
  @Test func partialFinderImportRefreshesSuccessfulContentAndConsumesCapturedSelection() async throws {
    let fixture = try await ActionFixture()
    let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = fixture.store
    var dismissals = 0
    let model = QuickSendModel(
      store: store,
      finderReader: ActionFinderReader(state: .selection([fixture.source, folder])),
      destinationResolver: RecentDestinationResolver(),
      dismiss: { dismissals += 1 }
    )
    await model.refresh()
    model.setQuery(fixture.source.lastPathComponent)

    model.performPrimary()
    await waitUntil { !model.isOperationRunning }

    #expect(dismissals == 0)
    #expect(model.query == fixture.source.lastPathComponent)
    #expect(model.inlineError != nil)
    #expect(model.resultsInGroup(.finderSelection).isEmpty)
    #expect(model.resultsInGroup(.temporary).map(\.title) == ["Source"])
    #expect(model.selectedResult?.shelfItemID == store.items.first?.id)

    model.performPrimary()
    await waitUntil { !model.isOperationRunning }
    #expect(store.liveItemCount == 1)
  }

  @Test func fullFinderImportDismissesAfterRefreshingResults() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    var dismissals = 0
    let model = QuickSendModel(
      store: store,
      finderReader: ActionFinderReader(state: .selection([fixture.source])),
      destinationResolver: RecentDestinationResolver(),
      dismiss: { dismissals += 1 }
    )
    await model.refresh()

    model.performPrimary()
    await waitUntil { !model.isOperationRunning }

    #expect(dismissals == 1)
    #expect(model.inlineError == nil)
    #expect(model.resultsInGroup(.temporary).count == 1)
  }

  @Test func recentDestinationAccessRemainsScopedAcrossAwaitedExport() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let first = try #require(store.items.first)
    _ = try await store.exportForQuickSend(
      itemID: first.id, to: fixture.destination, fileName: "Previous.txt"
    )
    _ = await store.importURLsForQuickSend([fixture.source])
    let access = AccessState()
    let resolver = RecentDestinationResolver(
      startAccessing: { _ in access.start(); return true },
      stopAccessing: { _ in access.stop() }
    )
    let model = QuickSendModel(
      store: store, finderReader: ActionFinderReader(state: .empty),
      destinationResolver: resolver, dismiss: {}
    )
    await model.refresh()
    model.selectedResultID = model.resultsInGroup(.temporary).first?.id

    model.performPrimary()
    model.activateResult(try #require(model.layerResults.first).id)
    await waitUntil { !model.isOperationRunning }

    #expect(access.starts == 1)
    #expect(access.stops == 1)
    #expect(!access.isActive)
    #expect(store.liveItemCount == 0)
  }

  @Test func choosingOlderDestinationExportsOnlyToThatExactFolder() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    let newerDestination = fixture.root.appendingPathComponent("Newer", isDirectory: true)
    try FileManager.default.createDirectory(at: newerDestination, withIntermediateDirectories: true)

    _ = await store.importURLsForQuickSend([fixture.source])
    var item = try #require(store.items.first)
    _ = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "OlderHistory.txt"
    )
    _ = await store.importURLsForQuickSend([fixture.source])
    item = try #require(store.items.first)
    _ = try await store.exportForQuickSend(
      itemID: item.id, to: newerDestination, fileName: "NewerHistory.txt"
    )
    _ = await store.importURLsForQuickSend([fixture.source])
    item = try #require(store.items.first)
    let model = QuickSendModel(
      store: store, finderReader: ActionFinderReader(state: .empty),
      destinationResolver: RecentDestinationResolver(), dismiss: {}
    )
    await model.refresh()
    model.selectedResultID = "item:\(item.id)"

    model.performPrimary()
    let olderChoice = try #require(model.layerResults.first(where: {
      $0.subtitle == fixture.destination.path
    }))
    model.activateResult(olderChoice.id)
    await waitUntil { !model.isOperationRunning }

    #expect(FileManager.default.fileExists(
      atPath: fixture.destination.appendingPathComponent("Source.txt").path
    ))
    #expect(!FileManager.default.fileExists(
      atPath: newerDestination.appendingPathComponent("Source.txt").path
    ))
  }

  @Test func finderImportReturnsPartialOutcomeAndRefreshesSuccessfulItems() async throws {
    let fixture = try await ActionFixture()
    let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = fixture.store

    let outcome = await store.importURLsForQuickSend([fixture.source, folder])

    #expect(outcome.successes.count == 1)
    #expect(outcome.failures.count == 1)
    #expect(store.liveItemCount == 1)
  }

  @Test func exportReturnsEventAndExactNameCollisionPreservesItem() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let item = try #require(store.items.first)

    let event = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "Sent.txt"
    )
    #expect(event.fileName == "Sent.txt")
    #expect(store.liveItemCount == 0)

    _ = await store.importURLsForQuickSend([fixture.source])
    let retry = try #require(store.items.first)
    await #expect(throws: RepositoryError.self) {
      _ = try await store.exportForQuickSend(
        itemID: retry.id, to: fixture.destination, fileName: "Sent.txt"
      )
    }
    #expect(store.liveItemCount == 1)
  }

  @Test func successfulUndoReturnsCommittedStatusAndRefreshes() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let item = try #require(store.items.first)
    let export = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "Undo.txt"
    )

    let outcome = try await store.undoForQuickSend(export)

    #expect(outcome.isCommitted)
    #expect(outcome.warning == nil)
    #expect(store.liveItemCount == 1)
    #expect(!store.isUndoEligible(export))
  }

  @Test func committedUndoCleanupWarningRefreshesAndKeepsQuickSendOpen() async throws {
    let manager = ActionUndoCleanupFailureFileManager()
    let fixture = try await ActionFixture(fileManager: manager)
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let item = try #require(store.items.first)
    _ = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "Cleanup.txt"
    )
    manager.failUndoCleanup = true
    var dismissals = 0
    let model = QuickSendModel(
      store: store, finderReader: ActionFinderReader(state: .empty),
      destinationResolver: RecentDestinationResolver(), dismiss: { dismissals += 1 }
    )
    model.setQuery("txt")
    await model.refresh()
    model.selectedResultID = try #require(model.resultsInGroup(.undoLatest).first).id

    model.performPrimary()
    await waitUntil { !model.isOperationRunning }

    #expect(dismissals == 0)
    #expect(model.query == "txt")
    #expect(model.selectedResult?.group == .temporary)
    #expect(model.resultsInGroup(.undoLatest).isEmpty)
    #expect(model.inlineError == "Undo was saved, but its recovery bytes could not be removed.")
  }

  @Test func ordinarySuccessfulUndoDismissesQuickSend() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let item = try #require(store.items.first)
    _ = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "Undo.txt"
    )
    var dismissals = 0
    let model = QuickSendModel(
      store: store, finderReader: ActionFinderReader(state: .empty),
      destinationResolver: RecentDestinationResolver(), dismiss: { dismissals += 1 }
    )
    await model.refresh()
    model.selectedResultID = model.resultsInGroup(.undoLatest).first?.id

    model.performPrimary()
    await waitUntil { !model.isOperationRunning }

    #expect(dismissals == 1)
    #expect(model.inlineError == nil)
  }

  @Test func importURLsRefreshesAfterAllFailureWithoutPostingChangeNotification() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    let external = await fixture.repository.importFiles(
      [fixture.source], origin: .imported, expiresAt: nil
    )
    #expect(external.successes.count == 1)
    let folder = fixture.root.appendingPathComponent("Folder", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var notifications = 0
    let token = NotificationCenter.default.addObserver(
      forName: .repositoryDidChange, object: store, queue: nil
    ) { _ in notifications += 1 }
    defer { NotificationCenter.default.removeObserver(token) }

    store.importURLs([folder])
    await waitUntil { store.errorMessage != nil }

    #expect(store.liveItemCount == 1)
    #expect(notifications == 0)
  }

  @Test func historyOpenAndRevealAreTolerantOfDeletion() async throws {
    let fixture = try await ActionFixture()
    let store = fixture.store
    _ = await store.importURLsForQuickSend([fixture.source])
    let item = try #require(store.items.first)
    let export = try await store.exportForQuickSend(
      itemID: item.id, to: fixture.destination, fileName: "Gone.txt"
    )
    try FileManager.default.removeItem(at: try #require(export.destinationURL))

    #expect(!store.openHistoryEvent(export))
    #expect(!store.revealHistoryEvent(export))
  }
}

private struct ActionFinderReader: FinderSelectionReading {
  let state: FinderSelectionState
  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState { state }
}

private final class AccessState: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var startCount = 0
  private var stopCount = 0
  var isActive: Bool { lock.withLock { active } }
  var starts: Int { lock.withLock { startCount } }
  var stops: Int { lock.withLock { stopCount } }
  func start() { lock.withLock { active = true; startCount += 1 } }
  func stop() { lock.withLock { active = false; stopCount += 1 } }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
  while !predicate() { await Task.yield() }
}

private final class ActionFixture: @unchecked Sendable {
  let root: URL
  let source: URL
  let destination: URL
  let repository: ShelfRepository

  @MainActor var store: ShelfStore {
    ShelfStore(repository: repository, indexesSpotlight: false, loadOnInit: false)
  }

  init(fileManager: FileManager = .default) async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("QuickSendActionTests-\(UUID().uuidString)", isDirectory: true)
    source = root.appendingPathComponent("Source.txt")
    destination = root.appendingPathComponent("Destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("contents".utf8).write(to: source)
    repository = ShelfRepository(configuration: RepositoryConfiguration(
      rootURL: root.appendingPathComponent("Repository", isDirectory: true), deviceID: "test"
    ), fileManager: fileManager)
    _ = try await repository.load()
  }

  deinit { try? FileManager.default.removeItem(at: root) }
}

private final class ActionUndoCleanupFailureFileManager: FileManager, @unchecked Sendable {
  var failUndoCleanup = false

  override func removeItem(at URL: URL) throws {
    if failUndoCleanup, URL.lastPathComponent.hasPrefix(".barrel-undo-") {
      throw CocoaError(.fileWriteNoPermission)
    }
    try super.removeItem(at: URL)
  }
}
