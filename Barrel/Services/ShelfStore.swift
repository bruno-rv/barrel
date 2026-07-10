import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ShelfStore: ObservableObject {
  @Published var items: [ShelfItem] = []
  @Published var selectedIDs: Set<ShelfItem.ID> = []
  @Published var searchText = ""
  @Published var filter: ShelfFilter = .all
  @Published var errorMessage: String?

  private let importer: ImportService

  init(importer: ImportService = ImportService()) {
    self.importer = importer
    load()
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
    let pasteboard = UIPasteboard.general
    do {
      if let image = pasteboard.image {
        insert([try importer.makeImageItem(image)])
      } else if let url = pasteboard.url {
        insert([importer.makeLinkItem(url)])
      } else if let string = pasteboard.string, !string.isEmpty {
        if let url = URL(string: string), url.scheme != nil {
          insert([importer.makeLinkItem(url)])
        } else {
          insert([importer.makeTextItem(string)])
        }
      } else {
        errorMessage = "The clipboard does not contain a file, image, link, or text item."
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func stackSelectedItems() {
    let selected = items.filter { selectedIDs.contains($0.id) }
    guard selected.count > 1 else {
      return
    }

    let stack = ShelfItem(
      title: stackTitle(for: selected),
      kind: .stack,
      children: selected
    )

    items.removeAll { selectedIDs.contains($0.id) }
    items.insert(stack, at: 0)
    selectedIDs = []
    save()
  }

  func splitStack(_ stack: ShelfItem) {
    guard let index = items.firstIndex(where: { $0.id == stack.id }), stack.isStack else {
      return
    }

    items.remove(at: index)
    items.insert(contentsOf: stack.children, at: index)
    save()
  }

  func delete(_ item: ShelfItem) {
    importer.deleteFiles(for: item)
    items.removeAll { $0.id == item.id }
    selectedIDs.remove(item.id)
    save()
  }

  func deleteSelectedItems() {
    let targets = items.filter { selectedIDs.contains($0.id) }
    targets.forEach { importer.deleteFiles(for: $0) }
    items.removeAll { selectedIDs.contains($0.id) }
    selectedIDs = []
    save()
  }

  func toggleSelection(for item: ShelfItem) {
    if selectedIDs.contains(item.id) {
      selectedIDs.remove(item.id)
    } else {
      selectedIDs.insert(item.id)
    }
  }

  func rename(_ item: ShelfItem, title: String) {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else {
      return
    }
    items[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title : title
    items[index].updatedAt = .now
    save()
  }

  private func load() {
    do {
      items = try importer.loadManifest()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func insert(_ newItems: [ShelfItem]) {
    guard !newItems.isEmpty else {
      return
    }
    items.insert(contentsOf: newItems, at: 0)
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
}

private extension ShelfItem {
  func matches(_ query: String) -> Bool {
    let haystacks = [title, subtitle, text ?? ""]
    if haystacks.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
      return true
    }
    return children.contains { $0.matches(query) }
  }
}
