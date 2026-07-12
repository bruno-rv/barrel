import AppKit
import XCTest
@testable import BarrelMac

final class FinderSelectionReaderTests: XCTestCase {
  func testReturnsOrderedFileAndFolderURLs() async {
    let first = URL(fileURLWithPath: "/tmp/first.txt")
    let second = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)
    let reader = FinderSelectionReader(
      frontmostBundleID: { "com.apple.finder" },
      execute: { .descriptor(Self.list([first, second])) }
    )

    let state = await reader.readSelection()
    XCTAssertEqual(state, .selection([first, second]))
  }

  func testReturnsEmptyForEmptySelection() async {
    let reader = FinderSelectionReader(
      frontmostBundleID: { "com.apple.finder" },
      execute: { .descriptor(NSAppleEventDescriptor.list()) }
    )

    let state = await reader.readSelection()
    XCTAssertEqual(state, .empty)
  }

  func testDoesNotExecuteWhenFinderIsNotFrontmost() async {
    let executor = RecordingFinderExecutor(result: .descriptor(Self.list([])))
    let reader = FinderSelectionReader(
      frontmostBundleID: { "com.example.other" },
      execute: { executor.execute() }
    )

    let state = await reader.readSelection()
    XCTAssertEqual(state, .unavailable)
    XCTAssertEqual(executor.callCount, 0)
  }

  func testMapsAutomationDenialToPermissionDenied() async {
    let reader = FinderSelectionReader(
      frontmostBundleID: { "com.apple.finder" },
      execute: { .failure(-1743) }
    )

    let state = await reader.readSelection()
    XCTAssertEqual(state, .permissionDenied)
  }

  func testMapsUnavailableFinderToUnavailable() async {
    let reader = FinderSelectionReader(
      frontmostBundleID: { "com.apple.finder" },
      execute: { .failure(-600) }
    )

    let state = await reader.readSelection()
    XCTAssertEqual(state, .unavailable)
  }

  func testParserRejectsNonListAndMalformedListDescriptors() {
    XCTAssertNil(FinderSelectionDescriptorParser.parse(NSAppleEventDescriptor(string: "not a list")))

    let malformed = NSAppleEventDescriptor.list()
    malformed.insert(NSAppleEventDescriptor(string: "not a file URL"), at: 1)
    XCTAssertNil(FinderSelectionDescriptorParser.parse(malformed))
  }

  private static func list(_ urls: [URL]) -> NSAppleEventDescriptor {
    let descriptor = NSAppleEventDescriptor.list()
    for (index, url) in urls.enumerated() {
      descriptor.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
    }
    return descriptor
  }
}

private final class RecordingFinderExecutor: @unchecked Sendable {
  private let lock = NSLock()
  private let result: FinderAppleEventResult
  private var calls = 0

  init(result: FinderAppleEventResult) {
    self.result = result
  }

  var callCount: Int { lock.withLock { calls } }

  func execute() -> FinderAppleEventResult {
    lock.withLock { calls += 1 }
    return result
  }
}
