import AppKit
import BarrelCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ShelfViewMode: Hashable {
  case bucket
  case history
  case trash
}

@MainActor
final class ShelfStore: ObservableObject, ShelfFilePromiseExporting {
  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var visibleItems: [ShelfItem] = []
  @Published private(set) var historyEvents: [HistoryEvent] = []
  @Published private(set) var viewMode: ShelfViewMode = .bucket
  @Published var selectedIDs: Set<ShelfItem.ID> = []
  @Published var selectedItemID: ShelfItem.ID?
  @Published var searchText = "" { didSet { recomputeVisibleItems() } }
  @Published var filter: ShelfFilter = .all { didSet { recomputeVisibleItems() } }
  @Published var errorMessage: String?
  @Published private(set) var isImporting = false
  @Published private(set) var storageUsage: Int64 = 0

  private let repository: ShelfRepository
  private let importer: ImportService
  private let indexesSpotlight: Bool
  private let spotlightIndexer = SpotlightIndexer()
  private var fileURLsByItemID: [UUID: URL] = [:]
  private var localOverlayItemIDs: Set<UUID> = []
  private var clipboardTask: Task<Void, Never>?
  private var spotlightTask: Task<Void, Never>?
  private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
  private var refreshGeneration = 0

  init(
    repository: ShelfRepository = BarrelEnvironment.shared.repository,
    importer: ImportService? = nil,
    indexesSpotlight: Bool = true,
    loadOnInit: Bool = true
  ) {
    self.repository = repository
    self.importer = importer ?? ImportService()
    self.indexesSpotlight = indexesSpotlight
    if loadOnInit {
      Task { await load() }
    }
  }

  var selectedItem: ShelfItem? {
    selectedItemID.flatMap(item(with:))
  }

  var liveItemCount: Int {
    items.lazy.filter { $0.trashedAt == nil && $0.deletedAt == nil }.count
  }

  func openBucket() {
    viewMode = .bucket
    if filter == .trash { filter = .all }
  }

  func openHistory() async {
    selectedIDs = []
    selectedItemID = nil
    viewMode = .history
    await refresh()
  }

  func openTrash() {
    viewMode = .trash
    filter = .trash
  }

  func undo(_ event: HistoryEvent) {
    Task { await performUndo(event) }
  }

  func performUndo(_ event: HistoryEvent) async {
    do {
      _ = try await repository.undo(historyEventID: event.id)
      notifyRepositoryChange()
      await refresh()
    } catch RepositoryError.undoCleanupFailed(let recovery) {
      notifyRepositoryChange()
      await refresh()
      errorMessage = Self.undoMessage(for: RepositoryError.undoCleanupFailed(recovery: recovery))
    } catch {
      errorMessage = Self.undoMessage(for: error)
    }
  }

  func isUndoEligible(_ event: HistoryEvent) -> Bool {
    guard event.kind == .export, event.reversedByEventID == nil else { return false }
    return historyEvents.first(where: {
      $0.itemID == event.itemID && $0.kind == .export && $0.reversedByEventID == nil
    })?.id == event.id
  }

  static func undoMessage(for error: Error) -> String {
    guard let repositoryError = error as? RepositoryError else {
      return error.localizedDescription
    }
    return repositoryError.errorDescription ?? error.localizedDescription
  }

  func item(with id: ShelfItem.ID) -> ShelfItem? {
    items.first { $0.id == id }
  }

  func fileURL(for item: ShelfItem) -> URL? {
    fileURLsByItemID[item.id]
  }

  func importWithOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.item]
    if panel.runModal() == .OK {
      importURLs(panel.urls)
    }
  }

  func importURLs(_ urls: [URL]) {
    Task {
      isImporting = true
      let outcome = await repository.importFiles(urls, origin: .imported, expiresAt: nil)
      isImporting = false
      report(errors: outcome.failures.map(\.message))
      if !outcome.successes.isEmpty { notifyRepositoryChange() }
      await refresh(preferredSelection: outcome.successes.first?.id)
    }
  }

  func importProviders(_ providers: [NSItemProvider]) {
    Task {
      isImporting = true
      let result = await importer.importItems(
        from: providers,
        into: repository,
        origin: .imported,
        expiresAt: nil
      )
      isImporting = false
      report(errors: result.errors)
      if !result.items.isEmpty { notifyRepositoryChange() }
      await refresh(preferredSelection: result.items.first?.id)
    }
  }

  func pasteFromClipboard() {
    Task {
      let pasteboard = NSPasteboard.general
      let result = await importer.importPasteboard(
        pasteboard,
        into: repository,
        origin: .imported,
        expiresAt: nil
      )
      lastPasteboardChangeCount = pasteboard.changeCount
      if result.items.isEmpty && result.errors.isEmpty {
        errorMessage = "The clipboard does not contain a file, image, link, or text item."
      } else {
        report(errors: result.errors)
        if !result.items.isEmpty { notifyRepositoryChange() }
        await refresh(preferredSelection: result.items.first?.id)
      }
    }
  }

  func setClipboardCapture(enabled: Bool) {
    clipboardTask?.cancel()
    clipboardTask = nil
    guard enabled else { return }
    lastPasteboardChangeCount = NSPasteboard.general.changeCount
    clipboardTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          return
        }
        guard let self else { return }
        await self.captureClipboardIfChanged()
      }
    }
  }

  func toggleSelection(for item: ShelfItem) {
    guard item.trashedAt == nil,
          item.deletedAt == nil,
          visibleItems.contains(where: { $0.id == item.id }) else {
      return
    }
    if selectedIDs.contains(item.id) {
      selectedIDs.remove(item.id)
    } else {
      selectedIDs.insert(item.id)
      selectedItemID = item.id
    }
  }

  func select(_ item: ShelfItem) {
    selectedItemID = item.id
  }

  func stackSelectedItems() {
    let ids = Array(selectedIDs)
    guard ids.count > 1, localOverlayItemIDs.isDisjoint(with: ids) else { return }
    Task {
      do {
        let stack = try await repository.stack(ids: ids)
        notifyRepositoryChange()
        selectedIDs = []
        await refresh(preferredSelection: stack.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func splitStack(_ stack: ShelfItem) {
    guard isCanonicalMutationEligible(stack) else { return }
    Task {
      do {
        try await repository.split(id: stack.id)
        notifyRepositoryChange()
        await refresh(preferredSelection: stack.children.first?.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func rename(_ item: ShelfItem, title: String) {
    guard isCanonicalMutationEligible(item) else { return }
    Task {
      do {
        try await repository.rename(id: item.id, title: title)
        notifyRepositoryChange()
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setPinned(_ item: ShelfItem, isPinned: Bool) {
    guard isCanonicalMutationEligible(item) else { return }
    Task {
      do {
        try await repository.setPinned(id: item.id, isPinned: isPinned)
        notifyRepositoryChange()
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setExpiration(_ item: ShelfItem, preset: ShelfExpirationPreset) {
    guard isCanonicalMutationEligible(item) else { return }
    Task {
      do {
        try await repository.setExpiration(id: item.id, date: preset.expirationDate(from: .now))
        notifyRepositoryChange()
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func trash(_ item: ShelfItem) {
    trash(ids: [item.id])
  }

  func trashSelectedItems() {
    trash(ids: Array(selectedIDs))
  }

  func restore(_ item: ShelfItem) {
    guard isCanonicalMutationEligible(item) else { return }
    Task {
      do {
        try await repository.restore(ids: [item.id])
        notifyRepositoryChange()
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func emptyTrash() {
    Task {
      do {
        try await repository.emptyTrash()
      } catch {
        errorMessage = error.localizedDescription
      }
      notifyRepositoryChange()
      await refresh()
    }
  }

  func deletePermanently(_ item: ShelfItem) {
    guard isCanonicalMutationEligible(item) else { return }
    Task {
      do {
        try await repository.deletePermanently(ids: [item.id])
      } catch {
        errorMessage = error.localizedDescription
      }
      notifyRepositoryChange()
      await refresh()
    }
  }

  func cleanup() {
    Task {
      do {
        let outcome = try await repository.cleanup()
        report(cleanup: outcome)
      } catch {
        errorMessage = error.localizedDescription
      }
      notifyRepositoryChange()
      await refresh(performsAutomaticCleanup: false)
    }
  }

  func setStorageQuota(_ bytes: Int) {
    Task {
      await repository.setStorageQuota(Int64(bytes))
      await refresh()
    }
  }

  func reveal(_ item: ShelfItem) {
    if let url = fileURL(for: item) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func open(_ item: ShelfItem) {
    if let url = fileURL(for: item) {
      NSWorkspace.shared.open(url)
    } else if item.kind == .link, let text = item.text, let url = URL(string: text) {
      NSWorkspace.shared.open(url)
    }
  }

  func itemProvider(for item: ShelfItem) -> NSItemProvider {
    if let url = fileURL(for: item) {
      return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
    if let text = item.text {
      return NSItemProvider(object: text as NSString)
    }
    return NSItemProvider(object: item.title as NSString)
  }

  func export(itemID: UUID, to directoryURL: URL, fileName: String) async throws -> HistoryEvent {
    do {
      let event = try await repository.export(itemID: itemID, to: directoryURL, fileName: fileName)
      notifyRepositoryChange()
      await refresh()
      return event
    } catch let error as RepositoryError {
      if case .exportPendingRecovery = error {
        notifyRepositoryChange()
        await refresh()
      }
      errorMessage = error.localizedDescription
      throw error
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func repositoryDidChange(selecting itemID: UUID? = nil) {
    if itemID != nil {
      filter = .all
      searchText = ""
    }
    Task {
      await refresh(preferredSelection: itemID)
    }
  }

  private func load() async {
    do {
      _ = try await repository.load()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func refresh(
    preferredSelection: UUID? = nil,
    performsAutomaticCleanup: Bool = true
  ) async -> Bool {
    refreshGeneration += 1
    let generation = refreshGeneration
    let temporaryItems = (try? await repository.temporarySnapshot()) ?? []
    let history = (try? await repository.historySnapshot()) ?? []
    let snapshot = await repository.snapshot()
    let temporaryItemIDs = Set(temporaryItems.map(\.id))
    let overlayItemIDs = Set(snapshot.lazy.filter {
      temporaryItemIDs.contains($0.id) && $0.deletedAt != nil
    }.map(\.id))
    let displayedSnapshot = temporaryItems + snapshot.filter {
      !temporaryItemIDs.contains($0.id) && $0.trashedAt != nil && $0.deletedAt == nil
    }
    var resolvedURLs: [UUID: URL] = [:]
    for item in displayedSnapshot {
      if let url = await repository.fileURL(for: item) {
        resolvedURLs[item.id] = url
      }
    }
    let usage = (try? await repository.storageUsage()) ?? 0
    guard generation == refreshGeneration else { return false }

    items = displayedSnapshot
    historyEvents = history
    fileURLsByItemID = resolvedURLs
    localOverlayItemIDs = overlayItemIDs
    storageUsage = usage
    recomputeVisibleItems(preferredSelection: preferredSelection)
    if indexesSpotlight {
      spotlightTask?.cancel()
      spotlightTask = Task { [weak self] in
        guard let self else { return }
        let indexingError = await spotlightIndexer.update(items: displayedSnapshot.filter {
          $0.trashedAt == nil && $0.deletedAt == nil
        })
        guard !Task.isCancelled, let indexingError, errorMessage == nil else { return }
        errorMessage = "Spotlight could not update the Barrel index: \(indexingError)"
      }
    }

    guard performsAutomaticCleanup else { return true }
    let cleanupResult: Result<CleanupOutcome, Error>
    do {
      cleanupResult = .success(try await repository.cleanup())
    } catch {
      cleanupResult = .failure(error)
    }
    guard generation == refreshGeneration else { return true }

    let applied = await refresh(
      preferredSelection: preferredSelection,
      performsAutomaticCleanup: false
    )
    guard applied else { return true }
    switch cleanupResult {
    case .success(let outcome):
      report(cleanup: outcome)
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
    return true
  }

  private func recomputeVisibleItems(preferredSelection: UUID? = nil) {
    visibleItems = filter.filter(items, query: searchText)
    let visibleIDs = Set(visibleItems.map(\.id))
    let liveVisibleIDs = Set(
      visibleItems.lazy.filter { $0.trashedAt == nil && $0.deletedAt == nil }.map(\.id)
    )
    selectedIDs.formIntersection(liveVisibleIDs.subtracting(localOverlayItemIDs))
    if viewMode == .history {
      selectedIDs = []
      selectedItemID = nil
      return
    }
    if let preferredSelection, visibleIDs.contains(preferredSelection) {
      selectedItemID = preferredSelection
    } else if selectedItemID.map(visibleIDs.contains) != true {
      selectedItemID = visibleItems.first?.id
    }
  }

  private func captureClipboardIfChanged() async {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
    lastPasteboardChangeCount = pasteboard.changeCount
    let hours = max(UserDefaults.standard.integer(forKey: "ClipboardLifetimeHours"), 1)
    let expiresAt = RetentionPolicy(clipboardLifetime: TimeInterval(hours * 3_600))
      .expirationDate(for: .clipboard, now: .now)
    let result = await importer.importPasteboard(
      pasteboard,
      into: repository,
      origin: .clipboard,
      expiresAt: expiresAt
    )
    report(errors: result.errors)
    if !result.items.isEmpty {
      notifyRepositoryChange()
      await refresh(preferredSelection: result.items.first?.id)
    }
  }

  private func trash(ids: [UUID]) {
    let ids = ids.filter { !localOverlayItemIDs.contains($0) }
    guard !ids.isEmpty else { return }
    Task {
      do {
        try await repository.trash(ids: ids)
        notifyRepositoryChange()
        selectedIDs.subtract(ids)
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func report(errors: [String]) {
    if !errors.isEmpty {
      errorMessage = errors.joined(separator: "\n")
    }
  }

  private func notifyRepositoryChange() {
    NotificationCenter.default.post(name: .repositoryDidChange, object: self)
  }

  func isCanonicalMutationEligible(_ item: ShelfItem) -> Bool {
    !localOverlayItemIDs.contains(item.id)
  }

  func isReadOnlyOverlay(_ item: ShelfItem) -> Bool {
    localOverlayItemIDs.contains(item.id)
  }

  private func report(cleanup outcome: CleanupOutcome) {
    guard outcome.requiresManualCleanup, errorMessage == nil else { return }
    let usage = ByteCountFormatter.string(fromByteCount: outcome.physicalUsageBytes, countStyle: .file)
    let quota = ByteCountFormatter.string(fromByteCount: outcome.quotaBytes, countStyle: .file)
    errorMessage = "Barrel is still using \(usage), above the \(quota) storage quota. Empty Trash or delete items manually to free space."
  }
}

extension ShelfStore {
  static var preview: ShelfStore {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BarrelPreview-\(UUID().uuidString)", isDirectory: true)
    let repository = ShelfRepository(
      configuration: RepositoryConfiguration(rootURL: root, deviceID: "preview")
    )
    let store = ShelfStore(repository: repository, loadOnInit: false)
    store.items = [.sampleStack, .samplePDF, .sampleText, .sampleLink]
    store.visibleItems = store.items
    store.selectedItemID = ShelfItem.sampleStack.id
    return store
  }
}
