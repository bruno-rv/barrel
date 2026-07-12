import BarrelCore
import Foundation

struct RecentDestination: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let url: URL
  let bookmark: Data?
  let lastUsedAt: Date
}

protocol RecentDestinationResolving: Sendable {
  func destinations(from events: [HistoryEvent]) -> [RecentDestination]
}

struct RecentDestinationResolver: RecentDestinationResolving, Sendable {
  private let now: @Sendable () -> Date
  private let retention: TimeInterval
  private let resolveBookmark: @Sendable (Data) -> URL?
  private let fileExists: @Sendable (URL) -> Bool
  private let startAccessing: @Sendable (URL) -> Bool
  private let stopAccessing: @Sendable (URL) -> Void

  init(
    now: @escaping @Sendable () -> Date = { Date() },
    retention: TimeInterval = 86_400,
    resolveBookmark: @escaping @Sendable (Data) -> URL? = { Self.resolveDirectoryBookmark($0) },
    fileExists: @escaping @Sendable (URL) -> Bool = { Self.directoryExists($0) },
    startAccessing: @escaping @Sendable (URL) -> Bool = {
      $0.startAccessingSecurityScopedResource()
    },
    stopAccessing: @escaping @Sendable (URL) -> Void = {
      $0.stopAccessingSecurityScopedResource()
    }
  ) {
    self.now = now
    self.retention = retention
    self.resolveBookmark = resolveBookmark
    self.fileExists = fileExists
    self.startAccessing = startAccessing
    self.stopAccessing = stopAccessing
  }

  func destinations(from events: [HistoryEvent]) -> [RecentDestination] {
    var seenPaths = Set<String>()
    let currentDate = now()

    return events
      .filter {
        $0.kind == .export
          && $0.reversedByEventID == nil
          && currentDate.timeIntervalSince($0.timestamp) < retention
      }
      .sorted {
        $0.timestamp == $1.timestamp
          ? $0.id.uuidString > $1.id.uuidString
          : $0.timestamp > $1.timestamp
      }
      .compactMap { event in
        let bookmarkURL = event.destinationDirectoryBookmark.flatMap(resolveBookmark)
        let legacyURL = event.destinationURL?.deletingLastPathComponent()
        guard let standardizedURL = [bookmarkURL, legacyURL]
          .compactMap({ $0?.standardizedFileURL })
          .first(where: fileExists)
        else {
          return nil
        }
        guard seenPaths.insert(standardizedURL.path).inserted else {
          return nil
        }
        let usedBookmark = bookmarkURL?.standardizedFileURL == standardizedURL
        return RecentDestination(
          id: standardizedURL.path,
          name: standardizedURL.lastPathComponent,
          url: standardizedURL,
          bookmark: usedBookmark ? event.destinationDirectoryBookmark : nil,
          lastUsedAt: event.timestamp
        )
      }
  }

  func withAccess<Result: Sendable>(
    to destination: RecentDestination,
    operation: @Sendable (URL) async throws -> Result
  ) async rethrows -> Result {
    let scoped = startAccessing(destination.url)
    defer {
      if scoped {
        stopAccessing(destination.url)
      }
    }
    return try await operation(destination.url)
  }

  private static func resolveDirectoryBookmark(_ data: Data) -> URL? {
    var isStale = false
    return try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
  }

  private static func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
