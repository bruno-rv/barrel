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

    XCTAssertEqual(exporter.calls, [.init(itemID: itemID, directoryURL: destination)])
    XCTAssertTrue(completions.isEmpty)

    exporter.resume()
    await waitUntil { completions.count == 1 }

    XCTAssertNil(completions[0])
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

  func testConstructionAndCancelledSessionDoNotExport() {
    let exporter = FakeExporter()
    let delegate = ShelfFilePromiseDelegate(
      itemID: UUID(),
      fileName: "asset.bin",
      exporter: exporter
    )
    let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)

    delegate.filePromiseProvider(
      provider,
      operationEnded: CocoaError(.userCancelled)
    )

    XCTAssertEqual(exporter.calls.count, 0)
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

  func export(itemID: UUID, to directoryURL: URL) async throws -> HistoryEvent {
    calls.append(.init(itemID: itemID, directoryURL: directoryURL))
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
