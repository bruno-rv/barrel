import BarrelCore
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

actor SpotlightIndexer {
  private let index = CSSearchableIndex.default()
  private let domainIdentifier = "dev.bruno.barrel.shelf"

  func update(items: [ShelfItem]) async {
    await removeAll()
    let searchableItems = items.compactMap { item -> CSSearchableItem? in
      guard item.trashedAt == nil else { return nil }
      let attributes = CSSearchableItemAttributeSet(contentType: .item)
      attributes.title = item.title
      attributes.contentDescription = String((item.text ?? item.detail).prefix(240))
      attributes.addedDate = item.createdAt
      attributes.keywords = [item.kind.label, "Barrel"]
      attributes.contentURL = URL(string: "barrel://item/\(item.id.uuidString)")
      return CSSearchableItem(
        uniqueIdentifier: item.id.uuidString,
        domainIdentifier: domainIdentifier,
        attributeSet: attributes
      )
    }
    guard !searchableItems.isEmpty else { return }
    await withCheckedContinuation { continuation in
      index.indexSearchableItems(searchableItems) { _ in
        continuation.resume()
      }
    }
  }

  func removeAll() async {
    await withCheckedContinuation { continuation in
      index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
        continuation.resume()
      }
    }
  }
}
