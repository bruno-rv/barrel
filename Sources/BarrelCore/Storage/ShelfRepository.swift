import CryptoKit
import Darwin
import Foundation

public actor ShelfRepository {
  private let configuration: RepositoryConfiguration
  private let fileManager: FileManager
  private var items: [ShelfItem] = []
  private var exportedItemIDs: Set<UUID> = []
  private var localItemSnapshots: [UUID: ShelfItem] = [:]
  private var history: [HistoryEvent] = []
  private var pendingExports: [PendingExport] = []
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
      exportedItemIDs = []
      localItemSnapshots = [:]
      history = []
      pendingExports = []
      try clearStaging()
      try removeOrphans()
      isLoaded = true
      return items
    }

    let decoded: RepositoryManifest
    do {
      let data = try Data(contentsOf: manifestURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      if let manifest = try? decoder.decode(RepositoryManifest.self, from: data) {
        decoded = manifest
      } else {
        decoded = RepositoryManifest(
          items: try decoder.decode([ShelfItem].self, from: data),
          exportedItemIDs: [],
          localItemSnapshots: [:],
          history: [],
          pendingExports: []
        )
      }
    } catch {
      try preserveCorruptManifest()
      try fileManager.removeItem(at: manifestURL)
      items = []
      isLoaded = true
      try? clearStaging()
      throw RepositoryError.corruptManifest
    }

    items = decoded.items
    exportedItemIDs = decoded.exportedItemIDs
    localItemSnapshots = decoded.localItemSnapshots
    history = decoded.history
    pendingExports = decoded.pendingExports
    try recoverPendingExports()
    let pruned = prunedState(
      items: items,
      exportedItemIDs: exportedItemIDs,
      localItemSnapshots: localItemSnapshots,
      history: history
    )
    try save(
      pruned.items,
      exportedItemIDs: pruned.exportedItemIDs,
      localItemSnapshots: pruned.localItemSnapshots,
      history: pruned.history
    )
    items = pruned.items
    exportedItemIDs = pruned.exportedItemIDs
    localItemSnapshots = pruned.localItemSnapshots
    history = pruned.history
    try clearStaging()
    try removeOrphans()
    isLoaded = true
    return items
  }

  public func snapshot() -> [ShelfItem] {
    items
  }

  public func temporarySnapshot() throws -> [ShelfItem] {
    try ensureLoaded()
    try pruneHistory()
    let pendingItemIDs = Set(pendingExports.map(\.item.id))
    let canonical = items.filter {
      !exportedItemIDs.contains($0.id)
        && !pendingItemIDs.contains($0.id)
        && localItemSnapshots[$0.id] == nil
        && $0.trashedAt == nil
        && $0.deletedAt == nil
        && $0.relativePath != nil
    }
    let restored = localItemSnapshots.values.filter {
      !exportedItemIDs.contains($0.id) && !pendingItemIDs.contains($0.id)
    }
    return canonical + restored
  }

  public func historySnapshot() throws -> [HistoryEvent] {
    try ensureLoaded()
    try pruneHistory()
    return history.sorted {
      $0.timestamp == $1.timestamp
        ? $0.id.uuidString < $1.id.uuidString
        : $0.timestamp > $1.timestamp
    }
  }

  @discardableResult
  public func export(itemID: UUID, to directoryURL: URL) throws -> HistoryEvent {
    try ensureLoaded()
    guard let item = exportableItem(id: itemID),
          let relativePath = item.relativePath,
          let sourceURL = managedURL(for: relativePath) else {
      throw RepositoryError.itemNotFound(itemID)
    }
    return try export(
      itemID: itemID,
      to: directoryURL,
      fileName: item.fileName ?? sourceURL.lastPathComponent
    )
  }

  @discardableResult
  public func export(itemID: UUID, to directoryURL: URL, fileName: String) throws -> HistoryEvent {
    try ensureLoaded()
    guard let item = exportableItem(id: itemID),
    let relativePath = item.relativePath,
    let sourceURL = managedURL(for: relativePath),
    let contentHash = item.contentHash else {
      throw RepositoryError.itemNotFound(itemID)
    }
    let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
    guard sourceValues.isRegularFile == true else {
      throw RepositoryError.itemNotFound(itemID)
    }

    guard !fileName.isEmpty,
          fileName != ".",
          fileName != "..",
          (fileName as NSString).lastPathComponent == fileName else {
      throw RepositoryError.invalidExportFileName(fileName)
    }
    let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    let privateExportDirectory = directoryURL.appendingPathComponent(".barrel-export-staging", isDirectory: true)
    let directories = try openExportDirectories(destinationDirectory: directoryURL, createStaging: true)
    defer { close(directories.staging); close(directories.destination) }
    try configuration.exportFaultInjector(.afterDirectoryValidation)
    try validateStagingDirectoryBinding(directories)
    let stagingName = UUID().uuidString
    let stagingURL = privateExportDirectory.appendingPathComponent(stagingName)
    let pending: PendingExport
    do {
      let stagedDescriptor = try copyExportSource(sourceURL, to: stagingName, in: directories.staging)
      defer { close(stagedDescriptor) }
      guard try Self.hash(fileDescriptor: stagedDescriptor) == contentHash else {
        throw RepositoryError.undoTargetChanged(stagingURL)
      }
      try configuration.exportFaultInjector(.afterStaging)
      let now = configuration.now()
      try configuration.exportFaultInjector(.beforeStagedIdentity)
      let stagedIdentity = try fileIdentity(fileDescriptor: stagedDescriptor, failureURL: stagingURL)
      let event = HistoryEvent(
        itemID: itemID,
        kind: .export,
        sourceName: "Barrel",
        destinationName: directoryURL.lastPathComponent,
        destinationURL: destinationURL,
        destinationBookmark: try? destinationURL.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ),
        fileName: destinationURL.lastPathComponent,
        contentHash: contentHash,
        timestamp: now,
        reversedEventID: nil,
        reversedByEventID: nil
      )
      pending = PendingExport(
        id: UUID(), item: item, stagingURL: stagingURL,
        destinationURL: destinationURL, contentHash: contentHash,
        systemNumber: stagedIdentity.systemNumber, fileNumber: stagedIdentity.fileNumber,
        event: event
      )
      try save(items, pendingExports: pendingExports + [pending])
    } catch {
      unlinkat(directories.staging, stagingName, 0)
      throw error
    }
    pendingExports.append(pending)
    do {
      try configuration.exportFaultInjector(.afterPendingCommit)
    } catch {
      throw RepositoryError.exportPendingRecovery(destinationURL, phase: .publicationPending)
    }
    do {
      try publishExportExclusively(
        stagingName: stagingName, stagingDirectory: directories.staging,
        destinationName: fileName, destinationDirectory: directories.destination
      )
    } catch {
      unlinkat(directories.staging, stagingName, 0)
      if pendingExports.contains(where: { $0.id == pending.id }) {
        try? cancel(pending)
      }
      let cocoaError = error as NSError
      if cocoaError.domain == NSPOSIXErrorDomain, cocoaError.code == Int(EEXIST) {
        throw RepositoryError.exportDestinationExists(destinationURL)
      }
      throw error
    }
    do {
      try configuration.exportFaultInjector(.afterPublish)
      try configuration.exportFaultInjector(.beforeFinalCommit)
    } catch {
      throw RepositoryError.exportPendingRecovery(destinationURL, phase: .publishedPendingFinalization)
    }
    do {
      try finalize(pending, destinationDirectory: directories.destination)
    } catch {
      throw RepositoryError.exportPendingRecovery(destinationURL, phase: .publishedPendingFinalization)
    }
    return pending.event
  }

  private func exportableItem(id: UUID) -> ShelfItem? {
    guard !exportedItemIDs.contains(id),
          !pendingExports.contains(where: { $0.item.id == id }),
          let canonical = items.first(where: { $0.id == id }) else {
      return nil
    }
    if canonical.trashedAt == nil, canonical.deletedAt == nil {
      return canonical
    }
    guard canonical.deletedAt != nil,
          let snapshot = localItemSnapshots[id],
          snapshot.trashedAt == nil,
          snapshot.deletedAt == nil else {
      return nil
    }
    return snapshot
  }

  private struct ExportDirectories { let destination: Int32; let staging: Int32 }

  private func openExportDirectories(destinationDirectory: URL, createStaging: Bool) throws -> ExportDirectories {
    let destination = open(destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard destination >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    do {
      if createStaging, mkdirat(destination, ".barrel-export-staging", 0o700) != 0, errno != EEXIST {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      let staging = openat(destination, ".barrel-export-staging", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      guard staging >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      do {
        guard fchmod(staging, 0o700) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var stagingInfo = stat()
        var destinationInfo = stat()
        guard fstat(staging, &stagingInfo) == 0, fstat(destination, &destinationInfo) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard stagingInfo.st_dev == destinationInfo.st_dev else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
        }
        return ExportDirectories(destination: destination, staging: staging)
      } catch {
        close(staging)
        throw error
      }
    } catch {
      close(destination)
      throw error
    }
  }

  private func validateStagingDirectoryBinding(_ directories: ExportDirectories) throws {
    var openedInfo = stat()
    var linkedInfo = stat()
    guard fstat(directories.staging, &openedInfo) == 0,
          fstatat(directories.destination, ".barrel-export-staging", &linkedInfo, AT_SYMLINK_NOFOLLOW) == 0,
          (linkedInfo.st_mode & S_IFMT) == S_IFDIR,
          openedInfo.st_dev == linkedInfo.st_dev,
          openedInfo.st_ino == linkedInfo.st_ino else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE))
    }
  }

  private func copyExportSource(_ sourceURL: URL, to name: String, in stagingDirectory: Int32) throws -> Int32 {
    let source = open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
    guard source >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(source) }
    var sourceInfo = stat()
    guard fstat(source, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EINVAL : errno))
    }
    let destination = openat(stagingDirectory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard destination >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    do {
      var buffer = [UInt8](repeating: 0, count: 1_048_576)
      while true {
        let count = read(source, &buffer, buffer.count)
        guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if count == 0 { break }
        var written = 0
        while written < count {
          let result = buffer.withUnsafeBytes {
            write(destination, $0.baseAddress!.advanced(by: written), count - written)
          }
          guard result > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
          written += result
        }
      }
      guard fsync(destination) == 0, lseek(destination, 0, SEEK_SET) >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      return destination
    } catch {
      close(destination)
      unlinkat(stagingDirectory, name, 0)
      throw error
    }
  }

  private func publishExportExclusively(
    stagingName: String, stagingDirectory: Int32,
    destinationName: String, destinationDirectory: Int32
  ) throws {
    let result = renameatx_np(
      stagingDirectory, stagingName, destinationDirectory, destinationName, UInt32(RENAME_EXCL)
    )
    guard result == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }

  private func finalize(_ pending: PendingExport, destinationDirectory: Int32? = nil) throws {
    let matches = destinationDirectory.map {
      isMatchingExport(named: pending.destinationURL.lastPathComponent, in: $0, pending: pending)
    } ?? isMatchingExport(at: pending.destinationURL, pending: pending)
    guard matches else {
      throw RepositoryError.undoTargetChanged(pending.destinationURL)
    }
    let updatedPending = pendingExports.filter { $0.id != pending.id }
    let pruned = prunedState(
      items: items,
      exportedItemIDs: exportedItemIDs.union([pending.item.id]),
      localItemSnapshots: localItemSnapshots.merging([pending.item.id: pending.item]) { _, value in value },
      history: history.contains(where: { $0.id == pending.event.id }) ? history : history + [pending.event]
    )
    try save(pruned.items, exportedItemIDs: pruned.exportedItemIDs,
             localItemSnapshots: pruned.localItemSnapshots, history: pruned.history,
             pendingExports: updatedPending)
    items = pruned.items
    exportedItemIDs = pruned.exportedItemIDs
    localItemSnapshots = pruned.localItemSnapshots
    history = pruned.history
    pendingExports = updatedPending
  }

  private func recoverPendingExports() throws {
    for pending in pendingExports {
      let stagingURL = pending.stagingURL
      let destinationDirectoryURL = pending.destinationURL.deletingLastPathComponent()
      let expectedStagingDirectory = destinationDirectoryURL
        .appendingPathComponent(".barrel-export-staging", isDirectory: true).standardizedFileURL
      guard stagingURL.deletingLastPathComponent().standardizedFileURL == expectedStagingDirectory,
            !stagingURL.lastPathComponent.isEmpty,
            (stagingURL.lastPathComponent as NSString).lastPathComponent == stagingURL.lastPathComponent,
            !pending.destinationURL.lastPathComponent.isEmpty else {
        try cancel(pending)
        continue
      }
      guard let directories = try? openExportDirectories(
        destinationDirectory: destinationDirectoryURL, createStaging: false
      ) else {
        try cancel(pending)
        continue
      }
      defer { close(directories.staging); close(directories.destination) }
      let stagingName = stagingURL.lastPathComponent
      let destinationName = pending.destinationURL.lastPathComponent
      if isMatchingExport(named: destinationName, in: directories.destination, pending: pending) {
        unlinkat(directories.staging, stagingName, 0)
        try finalize(pending, destinationDirectory: directories.destination)
      } else if !fileExists(named: destinationName, in: directories.destination),
                isMatchingExport(named: stagingName, in: directories.staging, pending: pending) {
        do {
          try publishExportExclusively(
            stagingName: stagingName, stagingDirectory: directories.staging,
            destinationName: destinationName, destinationDirectory: directories.destination
          )
          try finalize(pending, destinationDirectory: directories.destination)
        } catch {
          if isMatchingExport(named: destinationName, in: directories.destination, pending: pending) {
            try finalize(pending, destinationDirectory: directories.destination)
          } else {
            unlinkat(directories.staging, stagingName, 0)
            try cancel(pending)
          }
        }
      } else {
        unlinkat(directories.staging, stagingName, 0)
        try cancel(pending)
      }
    }
  }

  private func cancel(_ pending: PendingExport) throws {
    let updated = pendingExports.filter { $0.id != pending.id }
    try save(items, pendingExports: updated)
    pendingExports = updated
  }

  private struct FileIdentity {
    let systemNumber: UInt64
    let fileNumber: UInt64
  }

  private func fileIdentity(at url: URL) throws -> FileIdentity {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
          let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
      throw RepositoryError.undoTargetChanged(url)
    }
    return FileIdentity(systemNumber: system, fileNumber: file)
  }

  private func fileIdentity(fileDescriptor: Int32, failureURL: URL) throws -> FileIdentity {
    var info = stat()
    guard fstat(fileDescriptor, &info) == 0 else { throw RepositoryError.undoTargetChanged(failureURL) }
    return FileIdentity(systemNumber: UInt64(info.st_dev), fileNumber: UInt64(info.st_ino))
  }

  private func fileExists(named name: String, in directory: Int32) -> Bool {
    var info = stat()
    return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0
  }

  private func isMatchingExport(named name: String, in directory: Int32, pending: PendingExport) -> Bool {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          UInt64(info.st_dev) == pending.systemNumber,
          UInt64(info.st_ino) == pending.fileNumber else { return false }
    return (try? Self.hash(fileDescriptor: descriptor)) == pending.contentHash
  }

  private func isMatchingExport(at url: URL, pending: PendingExport) -> Bool {
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
    guard let identity = try? fileIdentity(at: url),
          identity.systemNumber == pending.systemNumber,
          identity.fileNumber == pending.fileNumber else { return false }
    return (try? Self.hash(file: url)) == pending.contentHash
  }

  @discardableResult
  public func undo(historyEventID: UUID) throws -> HistoryEvent {
    try ensureLoaded()
    guard let eventIndex = history.firstIndex(where: { $0.id == historyEventID }),
          history[eventIndex].kind == .export,
          history[eventIndex].reversedByEventID == nil,
          configuration.now().timeIntervalSince(history[eventIndex].timestamp) < configuration.historyRetention else {
      throw RepositoryError.undoIneligible(historyEventID)
    }
    let exportEvent = history[eventIndex]
    let latestExport = history
      .filter {
        $0.itemID == exportEvent.itemID
          && $0.kind == .export
          && $0.reversedByEventID == nil
          && configuration.now().timeIntervalSince($0.timestamp) < configuration.historyRetention
      }
      .max { lhs, rhs in
        lhs.timestamp == rhs.timestamp
          ? lhs.id.uuidString < rhs.id.uuidString
          : lhs.timestamp < rhs.timestamp
      }
    guard latestExport?.id == historyEventID,
          exportedItemIDs.contains(exportEvent.itemID) else {
      throw RepositoryError.undoIneligible(historyEventID)
    }

    let destinationURL = try resolvedDestination(for: exportEvent)
    guard let recordedURL = exportEvent.destinationURL,
          destinationURL.standardizedFileURL == recordedURL.standardizedFileURL else {
      throw RepositoryError.undoTargetChanged(exportEvent.destinationURL ?? destinationURL)
    }
    let scoped = destinationURL.startAccessingSecurityScopedResource()
    defer { if scoped { destinationURL.stopAccessingSecurityScopedResource() } }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) else {
      throw RepositoryError.undoTargetMissing(destinationURL)
    }
    guard !isDirectory.boolValue,
          (try? destinationURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      throw RepositoryError.undoTargetNotRegularFile(destinationURL)
    }
    let actualHash: String
    do {
      actualHash = try Self.hash(file: destinationURL)
    } catch {
      throw RepositoryError.undoTargetInaccessible(destinationURL)
    }
    guard actualHash == exportEvent.contentHash else {
      throw RepositoryError.undoTargetChanged(destinationURL)
    }

    let stagingURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".barrel-undo-\(UUID().uuidString)")
    do {
      try fileManager.moveItem(at: destinationURL, to: stagingURL)
    } catch {
      throw RepositoryError.undoTargetInaccessible(destinationURL)
    }
    let now = configuration.now()
    let undoEvent = HistoryEvent(
      itemID: exportEvent.itemID,
      kind: .undo,
      sourceName: exportEvent.destinationName,
      destinationName: "Barrel",
      destinationURL: destinationURL,
      destinationBookmark: exportEvent.destinationBookmark,
      fileName: exportEvent.fileName,
      contentHash: exportEvent.contentHash,
      timestamp: now,
      reversedEventID: exportEvent.id,
      reversedByEventID: nil
    )
    var candidateHistory = history
    candidateHistory[eventIndex].reversedByEventID = undoEvent.id
    candidateHistory.append(undoEvent)
    let candidateExportedIDs = exportedItemIDs.subtracting([exportEvent.itemID])
    let pruned = prunedState(
      items: items,
      exportedItemIDs: candidateExportedIDs,
      localItemSnapshots: localItemSnapshots,
      history: candidateHistory
    )
    let retainedItemIDs = Set(pruned.items.map(\.id))
    let removed = items.filter { !retainedItemIDs.contains($0.id) }
    do {
      try save(
        pruned.items,
        exportedItemIDs: pruned.exportedItemIDs,
        localItemSnapshots: pruned.localItemSnapshots,
        history: pruned.history
      )
    } catch {
      do {
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
      } catch {
        throw RepositoryError.undoRollbackFailed(destination: recordedURL, recovery: stagingURL)
      }
      throw error
    }
    items = pruned.items
    exportedItemIDs = pruned.exportedItemIDs
    localItemSnapshots = pruned.localItemSnapshots
    history = pruned.history
    do {
      try fileManager.removeItem(at: stagingURL)
    } catch {
      throw RepositoryError.undoCleanupFailed(recovery: stagingURL)
    }
    try deleteUnreferencedFiles(from: removed, remainingItems: items)
    return undoEvent
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
    let physicalUsage = try storageUsage()
    let candidates = Set(
      RetentionPolicy().cleanupCandidates(
        items: updated.filter { !exportedItemIDs.contains($0.id) },
        now: now,
        bytesByItemID: sizes,
        quotaBytes: quotaBytes,
        physicalUsageBytes: physicalUsage
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
          throw RepositoryError.missingSyncAsset(remotePath)
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

  private func save(
    _ items: [ShelfItem],
    exportedItemIDs: Set<UUID>? = nil,
    localItemSnapshots: [UUID: ShelfItem]? = nil,
    history: [HistoryEvent]? = nil,
    pendingExports: [PendingExport]? = nil
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let manifest = RepositoryManifest(
      items: items,
      exportedItemIDs: exportedItemIDs ?? self.exportedItemIDs,
      localItemSnapshots: localItemSnapshots ?? self.localItemSnapshots,
      history: history ?? self.history,
      pendingExports: pendingExports ?? self.pendingExports
    )
    let data = try encoder.encode(manifest)
    try configuration.manifestWriter(data, manifestURL)
  }

  private func pruneHistory() throws {
    let pruned = prunedState(
      items: items,
      exportedItemIDs: exportedItemIDs,
      localItemSnapshots: localItemSnapshots,
      history: history
    )
    guard pruned.items != items
      || pruned.exportedItemIDs != exportedItemIDs
      || pruned.localItemSnapshots != localItemSnapshots
      || pruned.history != history else { return }
    let retainedItemIDs = Set(pruned.items.map(\.id))
    let removedItems = items.filter { !retainedItemIDs.contains($0.id) }
    let removedSnapshots = localItemSnapshots.filter {
      pruned.localItemSnapshots[$0.key] == nil
    }.map(\.value)
    try save(
      pruned.items,
      exportedItemIDs: pruned.exportedItemIDs,
      localItemSnapshots: pruned.localItemSnapshots,
      history: pruned.history
    )
    items = pruned.items
    exportedItemIDs = pruned.exportedItemIDs
    localItemSnapshots = pruned.localItemSnapshots
    history = pruned.history
    try deleteUnreferencedFiles(from: removedItems + removedSnapshots, remainingItems: items)
  }

  private func prunedState(
    items: [ShelfItem],
    exportedItemIDs: Set<UUID>,
    localItemSnapshots: [UUID: ShelfItem],
    history: [HistoryEvent]
  ) -> RepositoryManifest {
    let now = configuration.now()
    let retainedHistory = history.filter {
      now.timeIntervalSince($0.timestamp) < configuration.historyRetention
    }
    let retainedHistoryItemIDs = Set(retainedHistory.map(\.itemID))
    let expiredExportedItemIDs = exportedItemIDs.subtracting(retainedHistoryItemIDs)
    let retainedSnapshots = localItemSnapshots.filter { retainedHistoryItemIDs.contains($0.key) }
    return RepositoryManifest(
      items: items.filter { !expiredExportedItemIDs.contains($0.id) },
      exportedItemIDs: exportedItemIDs.subtracting(expiredExportedItemIDs),
      localItemSnapshots: retainedSnapshots,
      history: retainedHistory
    )
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

  private nonisolated static func hash(fileDescriptor: Int32) throws -> String {
    guard lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      let count = read(fileDescriptor, &buffer, buffer.count)
      guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
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

  private func resolvedDestination(for event: HistoryEvent) throws -> URL {
    if let bookmark = event.destinationBookmark {
      do {
        var stale = false
        return try URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
      } catch {
        if let destinationURL = event.destinationURL { return destinationURL }
        throw RepositoryError.undoIneligible(event.id)
      }
    }
    guard let destinationURL = event.destinationURL else {
      throw RepositoryError.undoIneligible(event.id)
    }
    return destinationURL
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
    let references = Set(flattened(items + Array(localItemSnapshots.values)).compactMap(\.relativePath))
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
    let remainingPaths = Set(
      flattened(remainingItems + Array(localItemSnapshots.values)).compactMap(\.relativePath)
    )
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
      .filter {
        $0.origin == .clipboard
          && !$0.containsPinnedItem
          && !expiredIDs.contains($0.id)
      }
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

private struct RepositoryManifest: Codable {
  var items: [ShelfItem]
  var exportedItemIDs: Set<UUID>
  var localItemSnapshots: [UUID: ShelfItem]
  var history: [HistoryEvent]
  var pendingExports: [PendingExport]

  private enum CodingKeys: String, CodingKey {
    case items, exportedItemIDs, localItemSnapshots, history, pendingExports
  }

  init(
    items: [ShelfItem],
    exportedItemIDs: Set<UUID>,
    localItemSnapshots: [UUID: ShelfItem],
    history: [HistoryEvent],
    pendingExports: [PendingExport] = []
  ) {
    self.items = items
    self.exportedItemIDs = exportedItemIDs
    self.localItemSnapshots = localItemSnapshots
    self.history = history
    self.pendingExports = pendingExports
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedItems = try container.decode([ShelfItem].self, forKey: .items)
    let decodedExportedItemIDs = try container.decode(Set<UUID>.self, forKey: .exportedItemIDs)
    items = decodedItems
    exportedItemIDs = decodedExportedItemIDs
    localItemSnapshots = try container.decodeIfPresent([UUID: ShelfItem].self, forKey: .localItemSnapshots)
      ?? Dictionary(
        uniqueKeysWithValues: decodedItems
          .filter { decodedExportedItemIDs.contains($0.id) }
          .map { ($0.id, $0) }
      )
    history = try container.decode([HistoryEvent].self, forKey: .history)
    pendingExports = try container.decodeIfPresent([PendingExport].self, forKey: .pendingExports) ?? []
  }
}

private struct PendingExport: Codable, Equatable {
  let id: UUID
  let item: ShelfItem
  let stagingURL: URL
  let destinationURL: URL
  let contentHash: String
  let systemNumber: UInt64
  let fileNumber: UInt64
  let event: HistoryEvent
}
