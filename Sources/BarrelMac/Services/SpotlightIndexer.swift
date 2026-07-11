import BarrelCore
import CoreSpotlight
import Foundation
import OSLog
import UniformTypeIdentifiers

actor SpotlightIndexer {
  private let index = CSSearchableIndex.default()
  private let domainIdentifier = "dev.bruno.barrel.shelf"
  private let logger = Logger(subsystem: "dev.bruno.barrel", category: "Spotlight")
  private var pendingItems: [ShelfItem]?
  private var isUpdating = false
  private var indexedIDs: Set<String> = []
  private var isInitialized = false

  func update(items: [ShelfItem]) async -> String? {
    pendingItems = items
    guard !isUpdating else { return nil }
    isUpdating = true
    defer { isUpdating = false }
    var latestError: String?
    while let nextItems = pendingItems {
      pendingItems = nil
      do {
        try await apply(nextItems)
        latestError = nil
      } catch {
        latestError = error.localizedDescription
        logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    return latestError
  }

  func removeAll() async -> String? {
    pendingItems = nil
    do {
      try await deleteDomain()
      indexedIDs = []
      isInitialized = true
      return nil
    } catch {
      logger.error("Spotlight removal failed: \(error.localizedDescription, privacy: .public)")
      return error.localizedDescription
    }
  }

  private func apply(_ items: [ShelfItem]) async throws {
    let searchableItems = items.compactMap { item -> CSSearchableItem? in
      guard item.deletedAt == nil,
            item.trashedAt == nil,
            item.origin != .clipboard else {
        return nil
      }
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
    if !isInitialized {
      try await deleteDomain()
      isInitialized = true
    }
    let currentIDs = Set(searchableItems.map(\.uniqueIdentifier))
    let staleIDs = Array(indexedIDs.subtracting(currentIDs))
    if !staleIDs.isEmpty {
      try await deleteItems(withIdentifiers: staleIDs)
    }
    if !searchableItems.isEmpty {
      try await index(searchableItems)
    }
    indexedIDs = currentIDs
  }

  private func index(_ items: [CSSearchableItem]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      index.indexSearchableItems(items) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func deleteItems(withIdentifiers identifiers: [String]) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      index.deleteSearchableItems(withIdentifiers: identifiers) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func deleteDomain() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }
}
