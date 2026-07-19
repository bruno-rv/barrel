import AppKit
import BarrelCore
import XCTest
@testable import BarrelMac

@MainActor
final class FilePromiseDragSourceTests: XCTestCase {
  func testDelegateReportsPromisedFilenameWithoutExporting() {
    let exporter = FakeExporter()
    let delegate = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "Quarterly Report.pdf",
      exporter: exporter
    )
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)

    XCTAssertEqual(
      delegate.filePromiseProvider(provider, fileNameForType: "public.data"),
      "Quarterly Report.pdf"
    )
    XCTAssertEqual(exporter.calls.count, 0)
  }

  func testDelegateForwardsDestinationAndCompletesAfterExport() async {
    let itemID = UUID()
    let destination = URL(fileURLWithPath: "/tmp/promise-target", isDirectory: true)
    let exporter = FakeExporter(suspends: true)
    let delegate = ShelfFilePromiseDelegate(
      itemID: itemID,
      fileName: "asset.png",
      exporter: exporter
    )
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
    var completions: [Error?] = []

    delegate.filePromiseProvider(provider, writePromiseTo: destination) {
      completions.append($0)
    }
    await exporter.waitForCall()

    XCTAssertEqual(exporter.calls, [
      .init(itemID: itemID, directoryURL: destination, fileName: "asset.png")
    ])
    XCTAssertTrue(completions.isEmpty)

    exporter.resume()
    await waitUntil { completions.count == 1 }

    XCTAssertNil(completions[0])
  }

  func testDelegateTreatsFinderPromiseFileURLAsParentDirectoryPlusLeafName() async {
    let itemID = UUID()
    // Finder’s writePromiseTo is a file URL (often not yet created).
    let promiseFile = URL(fileURLWithPath: "/Users/bruno/Documents/CLAUDE.md", isDirectory: false)
    let exporter = FakeExporter()
    let delegate = ShelfFilePromiseDelegate(
      itemID: itemID,
      fileName: "CLAUDE.md",
      exporter: exporter
    )
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
    var completions: [Error?] = []

    delegate.filePromiseProvider(provider, writePromiseTo: promiseFile) {
      completions.append($0)
    }
    await waitUntil { completions.count == 1 }

    XCTAssertEqual(exporter.calls, [
      .init(
        itemID: itemID,
        directoryURL: URL(fileURLWithPath: "/Users/bruno/Documents", isDirectory: true),
        fileName: "CLAUDE.md"
      )
    ])
    XCTAssertNil(completions[0])
  }

  func testFilePromiseExportDestinationResolver() {
    let directory = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)
    let asDir = FilePromiseExportDestination.resolve(
      url: directory,
      fallbackFileName: "fallback.bin"
    )
    XCTAssertEqual(asDir.directoryURL.standardizedFileURL, directory.standardizedFileURL)
    XCTAssertEqual(asDir.fileName, "fallback.bin")

    let existingDir = FilePromiseExportDestination.resolve(
      url: URL(fileURLWithPath: "/tmp", isDirectory: false),
      fallbackFileName: "fallback.bin"
    )
    XCTAssertEqual(existingDir.directoryURL.standardizedFileURL.path, "/tmp")
    XCTAssertEqual(existingDir.fileName, "fallback.bin")

    let fileURL = URL(fileURLWithPath: "/tmp/does-not-exist-yet/Report.pdf", isDirectory: false)
    let asFile = FilePromiseExportDestination.resolve(
      url: fileURL,
      fallbackFileName: "fallback.bin"
    )
    XCTAssertEqual(asFile.directoryURL.path, "/tmp/does-not-exist-yet")
    XCTAssertEqual(asFile.fileName, "Report.pdf")
  }

  func testDelegateForwardsErrorOnce() async {
    let expected = TestError.exportFailed
    let exporter = FakeExporter(result: .failure(expected))
    let delegate = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter
    )
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)
    var completions: [Error?] = []

    delegate.filePromiseProvider(provider, writePromiseTo: URL(fileURLWithPath: "/tmp")) {
      completions.append($0)
    }
    await waitUntil { completions.count == 1 }

    XCTAssertEqual(completions.count, 1)
    XCTAssertEqual(completions[0] as? TestError, expected)
    XCTAssertEqual(exporter.calls.count, 1)
  }

  func testDelegateLivesThroughPromiseCompletion() async {
    let exporter = FakeExporter(suspends: true)
    var delegate: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter
    )
    weak let weakDelegate = delegate
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate!)
    var didComplete = false

    delegate!.filePromiseProvider(provider, writePromiseTo: URL(fileURLWithPath: "/tmp")) { _ in
      didComplete = true
    }
    await exporter.waitForCall()
    delegate = nil

    XCTAssertNotNil(weakDelegate)

    exporter.resume()
    await waitUntil { didComplete }
    await waitUntil { weakDelegate == nil }
  }

  func testCancelledSessionWithoutWriteReleasesDelegateAndDoesNotExport() {
    let exporter = FakeExporter()
    let lifecycle = FilePromiseDragLifecycle()
    var delegate: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter,
      lifecycle: lifecycle
    )
    weak let weakDelegate = delegate
    lifecycle.begin(delegate: delegate!)
    delegate = nil

    XCTAssertNotNil(weakDelegate)
    lifecycle.draggingSessionEnded(sessionID: weakDelegate!.lifecycleID, operation: [])

    XCTAssertNil(weakDelegate)
    XCTAssertEqual(exporter.calls.count, 0)
  }

  func testAcceptedSessionWithoutWriteReleasesDelegateAtLifecycleTeardown() {
    let exporter = FakeExporter()
    var lifecycle: FilePromiseDragLifecycle? = FilePromiseDragLifecycle()
    var delegate: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter,
      lifecycle: lifecycle
    )
    weak let weakDelegate = delegate
    lifecycle!.begin(delegate: delegate!)
    lifecycle!.draggingSessionEnded(sessionID: delegate!.lifecycleID, operation: .copy)
    delegate = nil

    XCTAssertNotNil(weakDelegate)
    lifecycle = nil

    XCTAssertNil(weakDelegate)
    XCTAssertEqual(exporter.calls.count, 0)
  }

  func testAcceptedWriteRetainsDelegateAfterSessionEndsUntilExportCompletes() async {
    let exporter = FakeExporter(suspends: true)
    let lifecycle = FilePromiseDragLifecycle()
    var delegate: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter,
      lifecycle: lifecycle
    )
    weak let weakDelegate = delegate
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate!)

    lifecycle.begin(delegate: delegate!)
    delegate = nil
    lifecycle.draggingSessionEnded(sessionID: weakDelegate!.lifecycleID, operation: .copy)

    XCTAssertNotNil(weakDelegate)
    weakDelegate!.filePromiseProvider(
      provider,
      writePromiseTo: URL(fileURLWithPath: "/tmp/promise-target")
    ) { _ in }
    await exporter.waitForCall()

    XCTAssertNotNil(weakDelegate)
    exporter.resume()
    await waitUntil { weakDelegate == nil }
  }

  func testAcceptedSessionReleasesDelegateWhenWriteCompletedBeforeSessionEnds() async {
    let exporter = FakeExporter()
    let lifecycle = FilePromiseDragLifecycle()
    var delegate: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter,
      lifecycle: lifecycle
    )
    weak let weakDelegate = delegate
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate!)
    var didComplete = false

    lifecycle.begin(delegate: delegate!)
    delegate!.filePromiseProvider(
      provider,
      writePromiseTo: URL(fileURLWithPath: "/tmp/promise-target")
    ) { _ in
      didComplete = true
    }
    delegate = nil
    await waitUntil { didComplete }

    XCTAssertNotNil(weakDelegate)
    lifecycle.draggingSessionEnded(sessionID: weakDelegate!.lifecycleID, operation: .copy)

    XCTAssertNil(weakDelegate)
  }

  func testOverlappingAcceptedDragsRetainEachDelegateUntilItsOwnWriteCompletes() async {
    let lifecycle = FilePromiseDragLifecycle()
    let exporterA = FakeExporter(suspends: true)
    var delegateA: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "a.bin",
      exporter: exporterA,
      lifecycle: lifecycle
    )
    weak let weakDelegateA = delegateA
    let providerA = NSFilePromiseProvider(fileType: "public.data", delegate: delegateA!)

    lifecycle.begin(delegate: delegateA!)
    delegateA!.filePromiseProvider(
      providerA,
      writePromiseTo: URL(fileURLWithPath: "/tmp/promise-a")
    ) { _ in }
    await exporterA.waitForCall()
    lifecycle.draggingSessionEnded(sessionID: weakDelegateA!.lifecycleID, operation: .copy)
    delegateA = nil

    let exporterB = FakeExporter(suspends: true)
    var delegateB: ShelfFilePromiseDelegate? = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "b.bin",
      exporter: exporterB,
      lifecycle: lifecycle
    )
    weak let weakDelegateB = delegateB
    let providerB = NSFilePromiseProvider(fileType: "public.data", delegate: delegateB!)

    lifecycle.begin(delegate: delegateB!)
    lifecycle.draggingSessionEnded(sessionID: weakDelegateB!.lifecycleID, operation: .copy)
    delegateB = nil

    exporterA.resume()
    await waitUntil { weakDelegateA == nil }

    XCTAssertNotNil(weakDelegateB)
    weakDelegateB!.filePromiseProvider(
      providerB,
      writePromiseTo: URL(fileURLWithPath: "/tmp/promise-b")
    ) { _ in }
    await exporterB.waitForCall()
    XCTAssertNotNil(weakDelegateB)

    exporterB.resume()
    await waitUntil { weakDelegateB == nil }
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<100 where !condition() {
      await Task.yield()
    }
    XCTAssertTrue(condition())
  }
}

private enum TestError: Error, Equatable {
  case exportFailed
}

@MainActor
private final class FakeExporter: ShelfFilePromiseExporting {
  struct Call: Equatable {
    let itemID: UUID
    let directoryURL: URL
    let fileName: String
  }

  private let result: Result<HistoryEvent, Error>
  private let suspends: Bool
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var calls: [Call] = []

  init(
    result: Result<HistoryEvent, Error> = .success(.fixture),
    suspends: Bool = false
  ) {
    self.result = result
    self.suspends = suspends
  }

  func export(itemID: UUID, to directoryURL: URL, fileName: String) async throws -> HistoryEvent {
    calls.append(.init(itemID: itemID, directoryURL: directoryURL, fileName: fileName))
    if suspends {
      await withCheckedContinuation { continuation = $0 }
    }
    return try result.get()
  }

  func waitForCall() async {
    for _ in 0..<100 where calls.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(calls.count, 1)
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private extension HistoryEvent {
  static let fixture = HistoryEvent(
    itemID: UUID(),
    kind: .export,
    sourceName: "asset.bin",
    destinationName: "promise-target",
    destinationURL: nil,
    destinationBookmark: nil,
    fileName: "asset.bin",
    contentHash: "hash",
    timestamp: .now,
    reversedEventID: nil,
    reversedByEventID: nil
  )
}
