import AppKit
import XCTest
@testable import BarrelMac

final class FinderSelectionReaderTests: XCTestCase {
  func testReturnsOrderedFileAndFolderURLs() async {
    let first = URL(fileURLWithPath: "/tmp/first.txt")
    let second = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)
    let reader = FinderSelectionReader(
      execute: { .descriptor(Self.list([first, second])) }
    )

    let state = await reader.readSelection(context: .finderWasFrontmost)
    XCTAssertEqual(state, .selection([first, second]))
  }

  func testReturnsEmptyForEmptySelection() async {
    let reader = FinderSelectionReader(
      execute: { .descriptor(NSAppleEventDescriptor.list()) }
    )

    let state = await reader.readSelection(context: .finderWasFrontmost)
    XCTAssertEqual(state, .empty)
  }

  func testDoesNotExecuteWhenFinderIsNotFrontmost() async {
    let executor = RecordingFinderExecutor(result: .descriptor(Self.list([])))
    let reader = FinderSelectionReader(
      execute: { executor.execute() }
    )

    let state = await reader.readSelection(context: .otherAppWasFrontmost)
    XCTAssertEqual(state, .unavailable)
    XCTAssertEqual(executor.callCount, 0)
  }

  func testMapsAutomationDenialToPermissionDenied() async {
    let reader = FinderSelectionReader(
      execute: { .failure(-1743) }
    )

    let state = await reader.readSelection(context: .finderWasFrontmost)
    XCTAssertEqual(state, .permissionDenied)
  }

  func testMapsUnavailableFinderToUnavailable() async {
    let reader = FinderSelectionReader(
      execute: { .failure(-600) }
    )

    let state = await reader.readSelection(context: .finderWasFrontmost)
    XCTAssertEqual(state, .unavailable)
  }

  func testParserRejectsNonListAndMalformedListDescriptors() {
    XCTAssertNil(FinderSelectionDescriptorParser.parse(NSAppleEventDescriptor(string: "not a list")))

    let malformed = NSAppleEventDescriptor.list()
    malformed.insert(NSAppleEventDescriptor(string: "not a file URL"), at: 1)
    XCTAssertNil(FinderSelectionDescriptorParser.parse(malformed))
  }

  func testParserRejectsAliasDescriptors() {
    let aliases = NSAppleEventDescriptor.list()
    aliases.insert(
      NSAppleEventDescriptor(descriptorType: typeAlias, data: Data("alias".utf8))!,
      at: 1
    )

    XCTAssertNil(FinderSelectionDescriptorParser.parse(aliases))
  }

  func testExecutorRequestsFinderSelectionAsAliases() {
    var sentEvent: NSAppleEventDescriptor?
    let executor = FinderAppleEventExecutor(
      send: { event in
        sentEvent = event
        return .descriptor(NSAppleEventDescriptor.list())
      },
      coerce: { _, _ in nil }
    )

    _ = executor.execute()

    XCTAssertEqual(sentEvent?.eventClass, AEEventClass(kAECoreSuite))
    XCTAssertEqual(sentEvent?.eventID, AEEventID(kAEGetData))
    XCTAssertEqual(
      sentEvent?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.descriptorType,
      typeObjectSpecifier
    )
    XCTAssertEqual(
      sentEvent?.paramDescriptor(forKeyword: AEKeyword(keyAERequestedType))?.typeCodeValue,
      typeAlias
    )
  }

  func testExecutorCoercesResolvedAliasesToFileURLsInOrder() {
    let first = URL(fileURLWithPath: "/tmp/first.txt")
    let second = URL(fileURLWithPath: "/tmp/second.txt")
    let raw = NSAppleEventDescriptor.list()
    raw.insert(Self.alias("first"), at: 1)
    raw.insert(Self.alias("second"), at: 2)
    var coercions: [(String?, DescType)] = []
    let executor = FinderAppleEventExecutor(
      send: { _ in .descriptor(raw) },
      coerce: { descriptor, type in
        let value = String(data: descriptor.data, encoding: .utf8)
        coercions.append((value, type))
        switch value {
        case "first": return NSAppleEventDescriptor(fileURL: first)
        case "second": return NSAppleEventDescriptor(fileURL: second)
        default: return nil
        }
      }
    )

    guard case let .descriptor(normalized) = executor.execute() else {
      return XCTFail("Expected a normalized descriptor")
    }
    XCTAssertEqual(FinderSelectionDescriptorParser.parse(normalized), [first, second])
    XCTAssertEqual(normalized.atIndex(1)?.descriptorType, typeFileURL)
    XCTAssertEqual(normalized.atIndex(2)?.descriptorType, typeFileURL)
    XCTAssertEqual(coercions.map(\.0), ["first", "second"])
    XCTAssertEqual(coercions.map(\.1), [typeFileURL, typeFileURL])
  }

  func testExecutorRejectsObjectSpecifierReplyWithoutLocalCoercion() {
    let raw = NSAppleEventDescriptor.list()
    raw.insert(
      NSAppleEventDescriptor(descriptorType: typeObjectSpecifier, data: Data("object".utf8))!,
      at: 1
    )
    var coercionCount = 0
    let executor = FinderAppleEventExecutor(
      send: { _ in .descriptor(raw) },
      coerce: { _, _ in
        coercionCount += 1
        return nil
      }
    )

    guard case .failure = executor.execute() else {
      return XCTFail("Expected normalization failure")
    }
    XCTAssertEqual(coercionCount, 0)
  }

  private static func list(_ urls: [URL]) -> NSAppleEventDescriptor {
    let descriptor = NSAppleEventDescriptor.list()
    for (index, url) in urls.enumerated() {
      descriptor.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
    }
    return descriptor
  }

  private static func alias(_ value: String) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(descriptorType: typeAlias, data: Data(value.utf8))!
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
