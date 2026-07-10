import CryptoKit
import Foundation

public actor ShelfRepository {
  private let configuration: RepositoryConfiguration
  private let fileManager: FileManager
  private var items: [ShelfItem] = []
  private var quotaBytes: Int64
  private var isLoaded = false

  private var itemsDirectory: URL {
    configuration.rootURL.appendingPathComponent("Items", isDirectory: true)
  }

  private var stagingDirectory: URL {
    configuration.rootURL.appendingPathComponent("Staging", isDirectory: true)
  }

  private var manifestURL: URL {
    configuration.rootURL.appendingPathComponent("shelf.json")
  }

  public init(configuration: RepositoryConfiguration, fileManager: FileManager = .default) {
    self.configuration = configuration
    self.fileManager = fileManager
    quotaBytes = configuration.quotaBytes
  }

  @discardableResult
  public func load() throws -> [ShelfItem] {
    guard !isLoaded else { return items }
    try prepareStorage()
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      items = []
      try clearStaging()
      try removeOrphans()
      isLoaded = true
      return items
    }

    let decoded: [ShelfItem]
    do {
      let data = try Data(contentsOf: manifestURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      decoded = try decoder.decode([ShelfItem].self, from: data)
    } catch {
      try preserveCorruptManifest()
      items = []
      throw RepositoryError.corruptManifest
    }

    try save(decoded)
    items = decoded
    try clearStaging()
    try removeOrphans()
    isLoaded = true
    return items
  }

  public func snapshot() -> [ShelfItem] {
    items
  }

  public func setStorageQuota(_ bytes: Int64) {
    quotaBytes = max(bytes, 0)
  }

  public func importFiles(
    _ urls: [URL],
    origin: ShelfOrigin,
    expiresAt: Date?
  ) async -> ImportOutcome {
    do {
      try ensureLoaded()
    } catch {
      return ImportOutcome(
        successes: [],
        failures: urls.map { ImportFailure(url: $0, message: error.localizedDescription) }
      )
    }

    let stagedResults = await stage(urls)
    var successes: [ShelfItem] = []
    var failures: [ImportFailure] = []
    for result in stagedResults.sorted(by: { $0.index < $1.index }) {
      switch result {
      case .failure(_, let url, let message):
        failures.append(ImportFailure(url: url, message: message))
      case .success(let staged):
        do {
          successes.append(try commit(staged, origin: origin, expiresAt: expiresAt))
        } catch {
          failures.append(ImportFailure(url: staged.sourceURL, message: error.localizedDescription))
        }
        try? fileManager.removeItem(at: staged.directory)
      }
    }
    return ImportOutcome(successes: successes, failures: failures)
  }

  public func addText(
    _ text: String,
    kind: ShelfKind,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) throws -> ShelfItem {
    try ensureLoaded()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first
    let fallback = kind == .link ? URL(string: trimmed)?.host : nil
    let title = fallback ?? firstLine.map { String($0.prefix(54)) } ?? kind.label
    let now = configuration.now()
    let item = ShelfItem(
      title: title.isEmpty ? kind.label : title,
      kind: kind,
      createdAt: now,
      updatedAt: now,
      text: text,
      origin: origin,
      expiresAt: expiresAt,
      revision: 1,
      modifiedByDeviceID: configuration.deviceID
    )
    try commitItems([item] + items)
    return item
  }

  public func rename(id: UUID, title: String) throws {
    try ensureLoaded()
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      throw RepositoryError.itemNotFound(id)
    }
    var updated = items
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      updated[index].title = trimmed
    }
    touch(&updated[index])
    try commitItems(updated)
  }

  @discardableResult
  public func stack(ids: [UUID]) throws -> ShelfItem {
    try ensureLoaded()
    let selectedIDs = Set(ids)
    let selected = items.filter { selectedIDs.contains($0.id) && $0.deletedAt == nil }
    guard selected.count >= 2 else {
      throw RepositoryError.invalidSelection
    }
    let firstIndex = items.firstIndex { selectedIDs.contains($0.id) } ?? 0
    let now = configuration.now()
    let inheritsClipboardRetention = selected.allSatisfy { $0.origin == .clipboard }
    let stack = ShelfItem(
      title: stackTitle(for: selected),
      kind: .stack,
      createdAt: now,
      updatedAt: now,
      children: selected,
      origin: inheritsClipboardRetention ? .clipboard : .imported,
      expiresAt: inheritsClipboardRetention ? selected.compactMap(\.expiresAt).min() : nil,
      revision: 1,
      modifiedByDeviceID: configuration.deviceID
    )
    var updated = items.filter { !selectedIDs.contains($0.id) }
    updated.insert(stack, at: min(firstIndex, updated.count))
    try commitItems(updated)
    return stack
  }

  public func split(id: UUID) throws {
    try ensureLoaded()
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      throw RepositoryError.itemNotFound(id)
    }
    let stack = items[index]
    guard stack.kind == .stack else {
      throw RepositoryError.invalidStack(id)
    }
    var updated = items
    updated.remove(at: index)
    updated.insert(contentsOf: stack.children, at: index)
    try commitItems(updated)
  }

  public func setPinned(id: UUID, isPinned: Bool) throws {
    try ensureLoaded()
    try update(id: id) { $0.isPinned = isPinned }
  }

  public func setExpiration(id: UUID, date: Date?) throws {
    try ensureLoaded()
    try update(id: id) { $0.expiresAt = date }
  }

  public func trash(ids: [UUID]) throws {
    try ensureLoaded()
    let targetIDs = Set(ids)
    let now = configuration.now()
    var updated = items
    for index in updated.indices
    where targetIDs.contains(updated[index].id)
      && updated[index].trashedAt == nil
      && updated[index].deletedAt == nil {
      updated[index].trashedAt = now
      touch(&updated[index], at: now)
    }
    if updated != items {
      try commitItems(updated)
    }
  }

  public func restore(ids: [UUID]) throws {
    try ensureLoaded()
    let targetIDs = Set(ids)
    let now = configuration.now()
    var updated = items
    for index in updated.indices
    where targetIDs.contains(updated[index].id) && updated[index].deletedAt == nil {
      updated[index].trashedAt = nil
      touch(&updated[index], at: now)
    }
    try commitItems(updated)
  }

  public func emptyTrash() throws {
    try ensureLoaded()
    let removed = items.filter { $0.trashedAt != nil && $0.deletedAt == nil }
    guard !removed.isEmpty else { return }
    let removedIDs = Set(removed.map(\.id))
    let now = configuration.now()
    let remaining = items.map { item in
      removedIDs.contains(item.id) ? tombstone(for: item, at: now) : item
    }
    try commitItems(remaining)
    try deleteUnreferencedFiles(from: removed, remainingItems: remaining)
  }

  public func deletePermanently(ids: [UUID]) throws {
    try ensureLoaded()
    let targetIDs = Set(ids)
    let removed = items.filter {
      targetIDs.contains($0.id) && $0.trashedAt != nil && $0.deletedAt == nil
    }
    guard !removed.isEmpty else { return }
    let removedIDs = Set(removed.map(\.id))
    let now = configuration.now()
    let remaining = items.map { item in
      removedIDs.contains(item.id) ? tombstone(for: item, at: now) : item
    }
    try commitItems(remaining)
    try deleteUnreferencedFiles(from: removed, remainingItems: remaining)
  }

  @discardableResult
  public func cleanup() throws -> CleanupOutcome {
    try ensureLoaded()
    let now = configuration.now()
    let trashCutoff = now.addingTimeInterval(-configuration.trashRetention)
    let permanentlyRemoved = items.filter { item in
      item.deletedAt == nil && item.trashedAt.map { $0 <= trashCutoff } == true
    }
    let permanentlyRemovedIDs = Set(permanentlyRemoved.map(\.id))
    var updated = items.map { item in
      permanentlyRemovedIDs.contains(item.id) ? tombstone(for: item, at: now) : item
    }
    let sizes = physicalBytesByItemID(updated, now: now)
    let candidates = Set(
      RetentionPolicy().cleanupCandidates(
        items: updated,
        now: now,
        bytesByItemID: sizes,
        quotaBytes: quotaBytes
      )
    )
    for index in updated.indices
    where candidates.contains(updated[index].id) && updated[index].deletedAt == nil {
      updated[index].trashedAt = now
      touch(&updated[index], at: now)
    }
    if updated != items {
      try commitItems(updated)
      try deleteUnreferencedFiles(from: permanentlyRemoved, remainingItems: updated)
    }
    return CleanupOutcome(physicalUsageBytes: try storageUsage(), quotaBytes: quotaBytes)
  }

  public func fileURL(for item: ShelfItem) -> URL? {
    item.relativePath.flatMap(managedURL(for:))
  }

  public func storageUsage() throws -> Int64 {
    guard fileManager.fileExists(atPath: itemsDirectory.path) else { return 0 }
    let enumerator = fileManager.enumerator(
      at: itemsDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
    )
    var total: Int64 = 0
    for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true {
        total += Int64(values.fileSize ?? 0)
      }
    }
    return total
  }

  public func syncRecords() throws -> [SyncRecord] {
    try ensureLoaded()
    return makeSyncRecords(from: items)
  }

  public func applySyncRecords(_ records: [SyncRecord]) throws {
    try Task.checkCancellation()
    try ensureLoaded()
    let previousItems = items
    let merged = SyncCoordinator.merge(
      local: makeSyncRecords(from: items),
      remote: records
    )
    var updated: [ShelfItem] = []
    var createdFiles: [URL] = []
    var createdDirectories: [URL] = []
    do {
      for record in merged {
        try Task.checkCancellation()
        var item = record.item
        try installAssets(
          in: &item,
          from: record.assetsByRelativePath,
          createdFiles: &createdFiles,
          createdDirectories: &createdDirectories
        )
        updated.append(item)
      }
      try Task.checkCancellation()
      try commitItems(updated)
    } catch {
      for file in createdFiles.reversed() {
        try? fileManager.removeItem(at: file)
      }
      for directory in createdDirectories.reversed() {
        try? fileManager.removeItem(at: directory)
      }
      throw error
    }
    try deleteUnreferencedFiles(from: previousItems, remainingItems: updated)
  }

  private func update(id: UUID, mutation: (inout ShelfItem) -> Void) throws {
    try ensureLoaded()
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      throw RepositoryError.itemNotFound(id)
    }
    var updated = items
    mutation(&updated[index])
    touch(&updated[index])
    try commitItems(updated)
  }

  private func touch(_ item: inout ShelfItem, at date: Date? = nil) {
    item.updatedAt = date ?? configuration.now()
    item.revision += 1
    item.modifiedByDeviceID = configuration.deviceID
  }

  private func tombstone(for item: ShelfItem, at date: Date) -> ShelfItem {
    var tombstone = item
    tombstone.title = "Deleted Item"
    tombstone.kind = .file
    tombstone.createdAt = date
    tombstone.updatedAt = date
    tombstone.text = nil
    tombstone.origin = .sync
    tombstone.expiresAt = nil
    tombstone.isPinned = false
    tombstone.trashedAt = nil
    tombstone.deletedAt = date
    tombstone.fileName = nil
    tombstone.relativePath = nil
    tombstone.contentHash = nil
    tombstone.children = []
    tombstone.revision += 1
    tombstone.modifiedByDeviceID = configuration.deviceID
    return tombstone
  }

  private func makeSyncRecords(from source: [ShelfItem]) -> [SyncRecord] {
    source.map { item in
      var assets: [String: URL] = [:]
      for nested in flattened([item]) {
        if let path = nested.relativePath,
           let url = managedURL(for: path),
           fileManager.fileExists(atPath: url.path) {
          assets[path] = url
        }
      }
      return SyncRecord(item: item, assetsByRelativePath: assets)
    }
  }

  private func installAssets(
    in item: inout ShelfItem,
    from assets: [String: URL],
    createdFiles: inout [URL],
    createdDirectories: inout [URL]
  ) throws {
    if item.deletedAt != nil {
      item.fileName = nil
      item.relativePath = nil
      item.children = []
      return
    }
    if let remotePath = item.relativePath {
      let existingURL = managedURL(for: remotePath)
      if existingURL.map({ fileManager.fileExists(atPath: $0.path) }) != true {
        guard let assetURL = assets[remotePath] else {
          item.relativePath = nil
          return
        }
        let proposedName = item.fileName ?? assetURL.lastPathComponent
        let safeFileName = proposedName.isEmpty
          ? "Synced File"
          : URL(fileURLWithPath: proposedName).lastPathComponent
        let managedDirectory = itemsDirectory
          .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let directoryExisted = fileManager.fileExists(atPath: managedDirectory.path)
        if !directoryExisted {
          try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
          createdDirectories.append(managedDirectory)
        }
        var destination = managedDirectory.appendingPathComponent(safeFileName)
        if fileManager.fileExists(atPath: destination.path) {
          destination = managedDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeFileName)")
        }
        let stagedDirectory = stagingDirectory
          .appendingPathComponent("Sync-\(UUID().uuidString)", isDirectory: true)
        let stagedFile = stagedDirectory.appendingPathComponent(destination.lastPathComponent)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagedDirectory) }
        try fileManager.copyItem(at: assetURL, to: stagedFile)
        try fileManager.moveItem(at: stagedFile, to: destination)
        createdFiles.append(destination)
        item.fileName = destination.lastPathComponent
        item.relativePath = makeRelativePath(for: destination)
      }
    }
    for index in item.children.indices {
      try installAssets(
        in: &item.children[index],
        from: assets,
        createdFiles: &createdFiles,
        createdDirectories: &createdDirectories
      )
    }
  }

  private func ensureLoaded() throws {
    if !isLoaded {
      _ = try load()
    }
  }

  private func prepareStorage() throws {
    try fileManager.createDirectory(at: configuration.rootURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
  }

  private func commitItems(_ updated: [ShelfItem]) throws {
    try save(updated)
    items = updated
  }

  private func save(_ items: [ShelfItem]) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(items)
    try configuration.manifestWriter(data, manifestURL)
  }

  private func preserveCorruptManifest() throws {
    let timestamp = Int64(configuration.now().timeIntervalSince1970)
    var backupURL = configuration.rootURL.appendingPathComponent("shelf-corrupt-\(timestamp).json")
    if fileManager.fileExists(atPath: backupURL.path) {
      backupURL = configuration.rootURL
        .appendingPathComponent("shelf-corrupt-\(timestamp)-\(UUID().uuidString).json")
    }
    try fileManager.copyItem(at: manifestURL, to: backupURL)
  }

  private func stage(_ urls: [URL]) async -> [StagingResult] {
    let stagingRoot = stagingDirectory
    return await withTaskGroup(of: StagingResult.self) { group in
      var iterator = urls.enumerated().makeIterator()
      for _ in 0..<min(4, urls.count) {
        if let next = iterator.next() {
          group.addTask { Self.stage(next.element, index: next.offset, stagingRoot: stagingRoot) }
        }
      }
      var results: [StagingResult] = []
      while let result = await group.next() {
        results.append(result)
        if let next = iterator.next() {
          group.addTask { Self.stage(next.element, index: next.offset, stagingRoot: stagingRoot) }
        }
      }
      return results
    }
  }

  private nonisolated static func stage(
    _ sourceURL: URL,
    index: Int,
    stagingRoot: URL
  ) -> StagingResult {
    let fileManager = FileManager.default
    let id = UUID()
    let directory = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    let fileName = sourceURL.lastPathComponent.isEmpty ? "Imported File" : sourceURL.lastPathComponent
    let stagedFile = directory.appendingPathComponent(fileName)
    do {
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw CocoaError(.fileReadNoSuchFile)
      }
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try fileManager.copyItem(at: sourceURL, to: stagedFile)
      let staged = StagedImport(
        index: index,
        sourceURL: sourceURL,
        id: id,
        directory: directory,
        fileURL: stagedFile,
        fileName: fileName,
        contentHash: try hash(file: stagedFile)
      )
      return .success(staged)
    } catch {
      try? fileManager.removeItem(at: directory)
      return .failure(index: index, url: sourceURL, message: error.localizedDescription)
    }
  }

  private nonisolated static func hash(file url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func commit(
    _ staged: StagedImport,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) throws -> ShelfItem {
    let existingPath = flattened(items).first { item in
      item.contentHash == staged.contentHash
        && item.relativePath.flatMap(managedURL(for:)).map { fileManager.fileExists(atPath: $0.path) } == true
    }?.relativePath
    let managedDirectory = itemsDirectory.appendingPathComponent(staged.id.uuidString, isDirectory: true)
    var relativePath = existingPath
    var installedNewFile = false

    if relativePath == nil {
      let destination = managedDirectory.appendingPathComponent(staged.fileName)
      try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
      do {
        try fileManager.moveItem(at: staged.fileURL, to: destination)
        installedNewFile = true
        relativePath = makeRelativePath(for: destination)
      } catch {
        try? fileManager.removeItem(at: managedDirectory)
        throw error
      }
    }

    let now = configuration.now()
    let item = ShelfItem(
      id: staged.id,
      title: staged.fileURL.deletingPathExtension().lastPathComponent,
      kind: kind(for: staged.fileURL),
      createdAt: now,
      updatedAt: now,
      fileName: staged.fileName,
      relativePath: relativePath,
      origin: origin,
      expiresAt: expiresAt,
      contentHash: staged.contentHash,
      revision: 1,
      modifiedByDeviceID: configuration.deviceID
    )
    do {
      try commitItems([item] + items)
      return item
    } catch {
      if installedNewFile {
        try? fileManager.removeItem(at: managedDirectory)
      }
      throw error
    }
  }

  private func managedURL(for relativePath: String) -> URL? {
    let root = configuration.rootURL.standardizedFileURL
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path.hasPrefix(rootPrefix),
          candidate.path.hasPrefix(itemsDirectory.standardizedFileURL.path + "/") else {
      return nil
    }
    return candidate
  }

  private func makeRelativePath(for url: URL) -> String {
    let rootPath = configuration.rootURL.standardizedFileURL.path
    return String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
  }

  private func kind(for url: URL) -> ShelfKind {
    let imageExtensions: Set<String> = ["avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
    return imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file
  }

  private func clearStaging() throws {
    for url in try fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil) {
      try fileManager.removeItem(at: url)
    }
  }

  private func removeOrphans() throws {
    let references = Set(flattened(items).compactMap(\.relativePath))
    for url in try fileManager.contentsOfDirectory(at: itemsDirectory, includingPropertiesForKeys: nil) {
      let relativeDirectory = "Items/\(url.lastPathComponent)"
      let isReferenced = references.contains { reference in
        reference == relativeDirectory || reference.hasPrefix(relativeDirectory + "/")
      }
      if !isReferenced {
        try fileManager.removeItem(at: url)
      }
    }
  }

  private func deleteUnreferencedFiles(
    from removedItems: [ShelfItem],
    remainingItems: [ShelfItem]
  ) throws {
    let remainingPaths = Set(flattened(remainingItems).compactMap(\.relativePath))
    let removedPaths = Set(flattened(removedItems).compactMap(\.relativePath))
    for path in removedPaths where !remainingPaths.contains(path) {
      guard let url = managedURL(for: path) else { continue }
      let directory = url.deletingLastPathComponent()
      if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
    }
  }

  private func physicalBytesByItemID(_ source: [ShelfItem], now: Date) -> [UUID: Int64] {
    let liveItems = source.filter { $0.trashedAt == nil && $0.deletedAt == nil }
    let expired = liveItems.filter { $0.isExpired(at: now) }.sorted(by: cleanupOrder)
    let expiredIDs = Set(expired.map(\.id))
    let clipboard = liveItems
      .filter { $0.origin == .clipboard && !$0.isPinned && !expiredIDs.contains($0.id) }
      .sorted(by: cleanupOrder)
    let removalRank = Dictionary(
      uniqueKeysWithValues: (expired + clipboard).enumerated().map { ($0.element.id, $0.offset) }
    )
    var referencesByPath: [String: [ShelfItem]] = [:]
    for item in liveItems {
      for path in Set(flattened([item]).compactMap(\.relativePath)) {
        referencesByPath[path, default: []].append(item)
      }
    }

    var bytesByItemID = Dictionary(uniqueKeysWithValues: liveItems.map { ($0.id, Int64(0)) })
    for (path, references) in referencesByPath {
      let owner = references.max { lhs, rhs in
        let lhsRank = removalRank[lhs.id] ?? Int.max
        let rhsRank = removalRank[rhs.id] ?? Int.max
        return lhsRank == rhsRank ? lhs.id.uuidString < rhs.id.uuidString : lhsRank < rhsRank
      }
      guard let owner,
            let url = managedURL(for: path),
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let number = attributes[.size] as? NSNumber else {
        continue
      }
      bytesByItemID[owner.id, default: 0] += number.int64Value
    }
    return bytesByItemID
  }

  private func cleanupOrder(_ lhs: ShelfItem, _ rhs: ShelfItem) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func flattened(_ source: [ShelfItem]) -> [ShelfItem] {
    source.flatMap { [$0] + flattened($0.children) }
  }

  private func stackTitle(for source: [ShelfItem]) -> String {
    let firstTwo = source.prefix(2).map(\.title).joined(separator: ", ")
    return source.count > 2 ? "\(firstTwo) + \(source.count - 2)" : firstTwo
  }
}

private struct StagedImport: Sendable {
  let index: Int
  let sourceURL: URL
  let id: UUID
  let directory: URL
  let fileURL: URL
  let fileName: String
  let contentHash: String
}

private enum StagingResult: Sendable {
  case success(StagedImport)
  case failure(index: Int, url: URL, message: String)

  var index: Int {
    switch self {
    case .success(let value): value.index
    case .failure(let index, _, _): index
    }
  }
}
