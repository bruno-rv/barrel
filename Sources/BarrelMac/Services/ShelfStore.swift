import AppKit
import BarrelCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfStore: ObservableObject {
  @Published private(set) var items: [ShelfItem] = []
  @Published private(set) var visibleItems: [ShelfItem] = []
  @Published var selectedIDs: Set<ShelfItem.ID> = []
  @Published var selectedItemID: ShelfItem.ID?
  @Published var searchText = "" { didSet { recomputeVisibleItems() } }
  @Published var filter: ShelfFilter = .all { didSet { recomputeVisibleItems() } }
  @Published var errorMessage: String?
  @Published private(set) var isImporting = false
  @Published private(set) var storageUsage: Int64 = 0

  private let repository: ShelfRepository
  private let importer: ImportService
  private var fileURLsByItemID: [UUID: URL] = [:]
  private var clipboardTask: Task<Void, Never>?
  private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

  init(
    repository: ShelfRepository = BarrelEnvironment.shared.repository,
    importer: ImportService? = nil,
    loadOnInit: Bool = true
  ) {
    self.repository = repository
    self.importer = importer ?? ImportService()
    if loadOnInit {
      Task { await load() }
    }
  }

  var selectedItem: ShelfItem? {
    selectedItemID.flatMap(item(with:))
  }

  var liveItemCount: Int {
    items.lazy.filter { $0.trashedAt == nil }.count
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
    guard ids.count > 1 else { return }
    Task {
      do {
        let stack = try await repository.stack(ids: ids)
        selectedIDs = []
        await refresh(preferredSelection: stack.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func splitStack(_ stack: ShelfItem) {
    Task {
      do {
        try await repository.split(id: stack.id)
        await refresh(preferredSelection: stack.children.first?.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func rename(_ item: ShelfItem, title: String) {
    Task {
      do {
        try await repository.rename(id: item.id, title: title)
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setPinned(_ item: ShelfItem, isPinned: Bool) {
    Task {
      do {
        try await repository.setPinned(id: item.id, isPinned: isPinned)
        await refresh(preferredSelection: item.id)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setExpiration(_ item: ShelfItem, preset: ShelfExpirationPreset) {
    Task {
      do {
        try await repository.setExpiration(id: item.id, date: preset.expirationDate(from: .now))
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
    Task {
      do {
        try await repository.restore(ids: [item.id])
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
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func deletePermanently(_ item: ShelfItem) {
    Task {
      do {
        try await repository.deletePermanently(ids: [item.id])
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func cleanup() {
    Task {
      do {
        try await repository.cleanup()
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setStorageQuota(_ bytes: Int) {
    Task {
      await repository.setStorageQuota(Int64(bytes))
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

  private func load() async {
    do {
      _ = try await repository.load()
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refresh(preferredSelection: UUID? = nil) async {
    items = await repository.snapshot()
    var resolvedURLs: [UUID: URL] = [:]
    for item in items {
      if let url = await repository.fileURL(for: item) {
        resolvedURLs[item.id] = url
      }
    }
    fileURLsByItemID = resolvedURLs
    storageUsage = (try? await repository.storageUsage()) ?? 0
    recomputeVisibleItems()
    selectedIDs.formIntersection(Set(items.map(\.id)))
    if let preferredSelection {
      selectedItemID = preferredSelection
    } else if selectedItemID.flatMap(item(with:)) == nil {
      selectedItemID = visibleItems.first?.id
    }
  }

  private func recomputeVisibleItems() {
    visibleItems = filter.filter(items, query: searchText)
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
      await refresh(preferredSelection: result.items.first?.id)
    }
  }

  private func trash(ids: [UUID]) {
    guard !ids.isEmpty else { return }
    Task {
      do {
        try await repository.trash(ids: ids)
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
