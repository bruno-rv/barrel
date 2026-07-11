import Foundation

public typealias ManifestWriter = @Sendable (_ data: Data, _ destination: URL) throws -> Void

public struct RepositoryConfiguration: Sendable {
  public static let defaultManifestWriter: ManifestWriter = { data, destination in
    try data.write(to: destination, options: .atomic)
  }

  public let rootURL: URL
  public let deviceID: String
  public let quotaBytes: Int64
  public let trashRetention: TimeInterval
  public let now: @Sendable () -> Date
  public let manifestWriter: ManifestWriter

  public init(
    rootURL: URL,
    deviceID: String,
    quotaBytes: Int64 = 1_073_741_824,
    trashRetention: TimeInterval = 604_800,
    now: @escaping @Sendable () -> Date = { Date() },
    manifestWriter: @escaping ManifestWriter = RepositoryConfiguration.defaultManifestWriter
  ) {
    self.rootURL = rootURL
    self.deviceID = deviceID
    self.quotaBytes = quotaBytes
    self.trashRetention = trashRetention
    self.now = now
    self.manifestWriter = manifestWriter
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
    }
  }
}
