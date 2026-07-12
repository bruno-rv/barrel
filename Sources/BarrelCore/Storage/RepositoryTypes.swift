import Foundation

public typealias ManifestWriter = @Sendable (_ data: Data, _ destination: URL) throws -> Void
public enum ExportFaultPoint: Sendable { case afterStaging, afterPendingCommit, afterPublish, beforeFinalCommit }
public typealias ExportFaultInjector = @Sendable (ExportFaultPoint) throws -> Void

public struct RepositoryConfiguration: Sendable {
  public static let defaultManifestWriter: ManifestWriter = { data, destination in
    try data.write(to: destination, options: .atomic)
  }

  public let rootURL: URL
  public let deviceID: String
  public let quotaBytes: Int64
  public let trashRetention: TimeInterval
  public let historyRetention: TimeInterval
  public let now: @Sendable () -> Date
  public let manifestWriter: ManifestWriter
  public let exportFaultInjector: ExportFaultInjector

  public init(
    rootURL: URL,
    deviceID: String,
    quotaBytes: Int64 = 1_073_741_824,
    trashRetention: TimeInterval = 604_800,
    historyRetention: TimeInterval = 86_400,
    now: @escaping @Sendable () -> Date = { Date() },
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter,
    exportFaultInjector: @escaping ExportFaultInjector = { _ in }
  ) {
    self.rootURL = rootURL
    self.deviceID = deviceID
    self.quotaBytes = quotaBytes
    self.trashRetention = trashRetention
    self.historyRetention = historyRetention
    self.now = now
    self.manifestWriter = manifestWriter
    self.exportFaultInjector = exportFaultInjector
  }
}

public struct ImportFailure: Equatable, Sendable {
  public let url: URL
  public let message: String

  public init(url: URL, message: String) {
    self.url = url
    self.message = message
  }
}

public struct ImportOutcome: Equatable, Sendable {
  public let successes: [ShelfItem]
  public let failures: [ImportFailure]

  public init(successes: [ShelfItem], failures: [ImportFailure]) {
    self.successes = successes
    self.failures = failures
  }
}

public struct CleanupOutcome: Equatable, Sendable {
  public let physicalUsageBytes: Int64
  public let quotaBytes: Int64

  public init(physicalUsageBytes: Int64, quotaBytes: Int64) {
    self.physicalUsageBytes = max(physicalUsageBytes, 0)
    self.quotaBytes = max(quotaBytes, 0)
  }

  public var requiresManualCleanup: Bool {
    physicalUsageBytes > quotaBytes
  }
}

public enum RepositoryError: Error, Equatable, Sendable {
  case corruptManifest
  case missingSyncAsset(String)
  case itemNotFound(UUID)
  case invalidStack(UUID)
  case invalidSelection
  case invalidExportFileName(String)
  case exportDestinationExists(URL)
  case exportPendingRecovery(URL)
  case undoIneligible(UUID)
  case undoTargetMissing(URL)
  case undoTargetChanged(URL)
  case undoTargetInaccessible(URL)
  case undoTargetNotRegularFile(URL)
  case undoRollbackFailed(destination: URL, recovery: URL)
  case undoCleanupFailed(recovery: URL)
}

extension RepositoryError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .corruptManifest:
      "Barrel could not read the shelf manifest. A backup of the corrupt file was preserved."
    case .missingSyncAsset(let path):
      "The synced item advertised an asset at \(path), but the asset was not downloaded."
    case .itemNotFound:
      "The shelf item no longer exists."
    case .invalidStack:
      "The selected item is not a stack."
    case .invalidSelection:
      "Select at least two shelf items."
    case .invalidExportFileName:
      "The promised export filename is invalid."
    case .exportDestinationExists(let url):
      "A file named \(url.lastPathComponent) already exists at the export destination."
    case .exportPendingRecovery:
      "The export was published, but Barrel must finish recording it on the next launch."
    case .undoIneligible:
      "This export is no longer eligible for Undo."
    case .undoTargetMissing:
      "The exported file is missing."
    case .undoTargetChanged:
      "The exported file has changed."
    case .undoTargetInaccessible:
      "The exported file is inaccessible."
    case .undoTargetNotRegularFile:
      "The export destination is no longer a regular file."
    case .undoRollbackFailed:
      "Undo could not restore the exported file after the shelf update failed. Recovery bytes were preserved."
    case .undoCleanupFailed:
      "Undo was saved, but its recovery bytes could not be removed."
    }
  }
}
