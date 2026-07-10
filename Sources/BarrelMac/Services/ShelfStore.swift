import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfStore: ObservableObject {
  @Published var items: [ShelfItem] = []
  @Published var selectedIDs: Set<ShelfItem.ID> = []
  @Published var selectedItemID: ShelfItem.ID?
  @Published var searchText = ""
  @Published var filter: ShelfFilter = .all
  @Published var errorMessage: String?

  private let importer: ImportService
  private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

  init(importer: ImportService = ImportService()) {
    self.importer = importer
    load()
  }

  var selectedItem: ShelfItem? {
    guard let selectedItemID else {
      return nil
    }
    return item(with: selectedItemID)
  }

  func visibleItems() -> [ShelfItem] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { item in
      filter.accepts(item) && (query.isEmpty || item.matches(query))
    }
  }

  func item(with id: ShelfItem.ID) -> ShelfItem? {
    items.first { $0.id == id }
  }

  func fileURL(for item: ShelfItem) -> URL? {
    importer.resolvedURL(for: item)
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
    do {
      let imported = try urls.map { try importer.makeFileItem(from: $0) }
      insert(imported)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importProviders(_ providers: [NSItemProvider]) {
    Task {
      do {
        let imported = try await importer.importItems(from: providers)
        insert(imported)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func pasteFromClipboard() {
    let pasteboard = NSPasteboard.general

    do {
      let imported = try clipboardItems(from: pasteboard)
      if imported.isEmpty {
        errorMessage = "The clipboard does not contain a file, image, link, or text item."
      } else {
        lastPasteboardChangeCount = pasteboard.changeCount
        insert(imported)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func captureClipboardIfChanged() {
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount != lastPasteboardChangeCount else {
      return
    }
    lastPasteboardChangeCount = pasteboard.changeCount

    do {
      let imported = try clipboardItems(from: pasteboard)
      insert(imported)
    } catch {
      errorMessage = error.localizedDescription
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
    let selected = items.filter { selectedIDs.contains($0.id) }
    guard selected.count > 1 else {
      return
    }

    let stack = ShelfItem(title: stackTitle(for: selected), kind: .stack, children: selected)
    items.removeAll { selectedIDs.contains($0.id) }
    items.insert(stack, at: 0)
    selectedIDs = []
    selectedItemID = stack.id
    save()
  }

  func splitStack(_ stack: ShelfItem) {
    guard let index = items.firstIndex(where: { $0.id == stack.id }), stack.isStack else {
      return
    }
    items.remove(at: index)
    items.insert(contentsOf: stack.children, at: index)
    selectedItemID = stack.children.first?.id
    save()
  }

  func rename(_ item: ShelfItem, title: String) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else {
      return
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    items[index].title = trimmed.isEmpty ? item.title : trimmed
    items[index].updatedAt = .now
    save()
  }

  func delete(_ item: ShelfItem) {
    importer.deleteFiles(for: item)
    items.removeAll { $0.id == item.id }
    selectedIDs.remove(item.id)
    if selectedItemID == item.id {
      selectedItemID = items.first?.id
    }
    save()
  }

  func deleteSelectedItems() {
    let targets = items.filter { selectedIDs.contains($0.id) }
    targets.forEach { importer.deleteFiles(for: $0) }
    items.removeAll { selectedIDs.contains($0.id) }
    selectedIDs = []
    selectedItemID = items.first?.id
    save()
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

  private func load() {
    do {
      items = try importer.loadManifest()
      selectedItemID = items.first?.id
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func insert(_ newItems: [ShelfItem]) {
    guard !newItems.isEmpty else {
      return
    }
    items.insert(contentsOf: newItems, at: 0)
    selectedItemID = newItems.first?.id
    save()
  }

  private func save() {
    do {
      try importer.saveManifest(items)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func stackTitle(for items: [ShelfItem]) -> String {
    let firstTwo = items.prefix(2).map(\.title).joined(separator: ", ")
    if items.count > 2 {
      return "\(firstTwo) + \(items.count - 2)"
    }
    return firstTwo
  }

  private func clipboardItems(from pasteboard: NSPasteboard) throws -> [ShelfItem] {
    if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
      return try fileURLs.map { try importer.makeFileItem(from: $0) }
    }
    if let image = NSImage(pasteboard: pasteboard) {
      return [try importer.makeImageItem(image)]
    }
    if let string = pasteboard.string(forType: .URL),
       let url = URL(string: string) {
      return [importer.makeLinkItem(url)]
    }
    if let string = pasteboard.string(forType: .string), !string.isEmpty {
      if let url = URL(string: string), url.scheme != nil {
        return [importer.makeLinkItem(url)]
      }
      return [importer.makeTextItem(string)]
    }
    return []
  }
}

extension ShelfStore {
  @MainActor
  static var preview: ShelfStore {
    let store = ShelfStore(importer: ImportService())
    store.items = [.sampleStack, .samplePDF, .sampleText, .sampleLink]
    store.selectedItemID = ShelfItem.sampleStack.id
    return store
  }
}
