import BarrelCore
import Foundation
import XCTest
@testable import BarrelMac

final class RecentDestinationResolverTests: XCTestCase {
  func testResolvesBookmarkBeforeLegacyURLAndOrdersNewestFirst() throws {
    let desktop = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
    let documents = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)
    let bookmark = Data("desktop".utf8)
    let newest = event(
      destinationURL: URL(fileURLWithPath: "/ignored/file.txt"),
      bookmark: bookmark,
      timestamp: Date(timeIntervalSince1970: 2)
    )
    let older = event(
      destinationURL: documents.appendingPathComponent("file.txt"),
      timestamp: Date(timeIntervalSince1970: 1)
    )
    let resolver = RecentDestinationResolver(
      now: { Date(timeIntervalSince1970: 10) },
      resolveBookmark: { $0 == bookmark ? desktop : nil },
      fileExists: { [desktop, documents].contains($0.standardizedFileURL) }
    )

    let destinations = resolver.destinations(from: [older, newest])

    XCTAssertEqual(destinations.map(\.url), [desktop, documents])
    XCTAssertEqual(destinations.first?.bookmark, bookmark)
    XCTAssertEqual(destinations.first?.lastUsedAt, newest.timestamp)
  }

  func testDeduplicatesStandardizedPathsWithNewestEventWinning() throws {
    let directory = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)
    let equivalentDirectory = directory.appendingPathComponent("Folder/..").standardizedFileURL
    let newer = event(
      destinationURL: equivalentDirectory.appendingPathComponent("new.txt"),
      timestamp: Date(timeIntervalSince1970: 3)
    )
    let older = event(
      destinationURL: directory.appendingPathComponent("old.txt"),
      timestamp: Date(timeIntervalSince1970: 1)
    )
    let resolver = RecentDestinationResolver(
      now: { Date(timeIntervalSince1970: 10) },
      resolveBookmark: { _ in nil },
      fileExists: { $0.standardizedFileURL == directory }
    )

    let destinations = resolver.destinations(from: [newer, older])

    XCTAssertEqual(destinations.count, 1)
    XCTAssertEqual(destinations[0].url, directory)
    XCTAssertEqual(destinations[0].lastUsedAt, newer.timestamp)
  }

  func testIgnoresUndoReversedMissingAndNonDirectoryEvents() throws {
    let validDirectory = URL(fileURLWithPath: "/valid", isDirectory: true)
    let missingDirectory = URL(fileURLWithPath: "/missing", isDirectory: true)
    var reversed = event(destinationURL: validDirectory.appendingPathComponent("reversed.txt"))
    reversed.reversedByEventID = UUID()
    let undo = event(
      kind: .undo,
      destinationURL: validDirectory.appendingPathComponent("undo.txt")
    )
    let missing = event(destinationURL: missingDirectory.appendingPathComponent("missing.txt"))
    let noURL = event(destinationURL: nil)
    let resolver = RecentDestinationResolver(
      now: { Date(timeIntervalSince1970: 10) },
      resolveBookmark: { _ in nil },
      fileExists: { $0.standardizedFileURL == validDirectory }
    )

    XCTAssertTrue(resolver.destinations(from: [reversed, undo, missing, noURL]).isEmpty)
    XCTAssertTrue(resolver.destinations(from: []).isEmpty)
  }

  func testExcludesEventsAtOrBeyondRetentionBoundaryAndRetainsFutureEvents() {
    let now = Date(timeIntervalSince1970: 200_000)
    let directory = URL(fileURLWithPath: "/valid", isDirectory: true)
    let withinRetention = event(
      destinationURL: directory.appendingPathComponent("within.txt"),
      timestamp: now.addingTimeInterval(-86_399)
    )
    let atBoundary = event(
      destinationURL: directory.appendingPathComponent("boundary.txt"),
      timestamp: now.addingTimeInterval(-86_400)
    )
    let expired = event(
      destinationURL: directory.appendingPathComponent("expired.txt"),
      timestamp: now.addingTimeInterval(-86_401)
    )
    let futureDirectory = URL(fileURLWithPath: "/future", isDirectory: true)
    let future = event(
      destinationURL: futureDirectory.appendingPathComponent("future.txt"),
      timestamp: now.addingTimeInterval(1)
    )
    let resolver = RecentDestinationResolver(
      now: { now },
      resolveBookmark: { _ in nil },
      fileExists: { [directory, futureDirectory].contains($0.standardizedFileURL) }
    )

    let destinations = resolver.destinations(
      from: [withinRetention, atBoundary, expired, future]
    )

    XCTAssertEqual(destinations.map(\.url), [futureDirectory, directory])
  }

  func testFallsBackToLegacyParentWhenResolvedBookmarkIsNotAValidDirectory() {
    let bookmark = Data("missing-bookmark".utf8)
    let missingBookmarkDirectory = URL(fileURLWithPath: "/missing", isDirectory: true)
    let legacyDirectory = URL(fileURLWithPath: "/legacy", isDirectory: true)
    let export = event(
      destinationURL: legacyDirectory.appendingPathComponent("file.txt"),
      bookmark: bookmark
    )
    let resolver = RecentDestinationResolver(
      now: { Date(timeIntervalSince1970: 10) },
      resolveBookmark: { $0 == bookmark ? missingBookmarkDirectory : nil },
      fileExists: { $0.standardizedFileURL == legacyDirectory }
    )

    let destinations = resolver.destinations(from: [export])

    XCTAssertEqual(destinations.map(\.url), [legacyDirectory])
    XCTAssertNil(destinations.first?.bookmark)
  }

  func testSecurityScopeRemainsActiveUntilAwaitedOperationReturns() async throws {
    let directory = URL(fileURLWithPath: "/scoped", isDirectory: true)
    let state = LockedScopeState()
    let destination = RecentDestination(
      id: directory.path,
      name: directory.lastPathComponent,
      url: directory,
      bookmark: Data("bookmark".utf8),
      lastUsedAt: Date()
    )
    let resolver = RecentDestinationResolver(
      resolveBookmark: { _ in nil },
      fileExists: { _ in true },
      startAccessing: { _ in state.start() },
      stopAccessing: { _ in state.stop() }
    )

    let result = await resolver.withAccess(to: destination) { url in
      XCTAssertEqual(url, directory)
      XCTAssertTrue(state.isActive)
      await Task.yield()
      XCTAssertTrue(state.isActive)
      return "exported"
    }

    XCTAssertEqual(result, "exported")
    XCTAssertFalse(state.isActive)
    XCTAssertEqual(state.stopCount, 1)
  }

  private func event(
    kind: HistoryEventKind = .export,
    destinationURL: URL?,
    bookmark: Data? = nil,
    timestamp: Date = Date(timeIntervalSince1970: 1)
  ) -> HistoryEvent {
    HistoryEvent(
      itemID: UUID(),
      kind: kind,
      sourceName: "Source",
      destinationName: destinationURL?.lastPathComponent ?? "",
      destinationURL: destinationURL,
      destinationBookmark: nil,
      destinationDirectoryBookmark: bookmark,
      fileName: destinationURL?.lastPathComponent ?? "",
      contentHash: "hash",
      timestamp: timestamp,
      reversedEventID: nil,
      reversedByEventID: nil
    )
  }
}

private final class LockedScopeState: @unchecked Sendable {
  private let lock = NSLock()
  private var active = false
  private var stops = 0

  var isActive: Bool { lock.withLock { active } }
  var stopCount: Int { lock.withLock { stops } }

  func start() -> Bool {
    lock.withLock { active = true }
    return true
  }

  func stop() {
    lock.withLock {
      active = false
      stops += 1
    }
  }
}
