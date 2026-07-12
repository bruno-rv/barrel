import AppKit
import Foundation

enum FinderSelectionState: Equatable, Sendable {
  case selection([URL])
  case empty
  case unavailable
  case permissionDenied
}

protocol FinderSelectionReading: Sendable {
  func readSelection() async -> FinderSelectionState
}

enum FinderAppleEventResult: @unchecked Sendable {
  case descriptor(NSAppleEventDescriptor)
  case failure(Int)
}

enum FinderSelectionDescriptorParser {
  static func parse(_ descriptor: NSAppleEventDescriptor) -> [URL]? {
    guard descriptor.descriptorType == typeAEList else {
      return nil
    }

    var urls: [URL] = []
    urls.reserveCapacity(descriptor.numberOfItems)
    for index in 0..<descriptor.numberOfItems {
      guard let item = descriptor.atIndex(index + 1),
            item.descriptorType == typeFileURL || item.descriptorType == typeAlias,
            let url = item.fileURLValue
      else {
        return nil
      }
      urls.append(url)
    }
    return urls
  }
}

struct FinderSelectionReader: FinderSelectionReading, Sendable {
  private let frontmostBundleID: @Sendable () -> String?
  private let execute: @Sendable () -> FinderAppleEventResult

  init(
    frontmostBundleID: @escaping @Sendable () -> String? = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    },
    execute: @escaping @Sendable () -> FinderAppleEventResult = {
      Self.executeSelectionScript()
    }
  ) {
    self.frontmostBundleID = frontmostBundleID
    self.execute = execute
  }

  func readSelection() async -> FinderSelectionState {
    guard frontmostBundleID() == "com.apple.finder" else {
      return .unavailable
    }

    let execute = execute
    let result = await Task.detached(priority: .userInitiated) {
      execute()
    }.value

    switch result {
    case .failure(-1743):
      return .permissionDenied
    case .failure:
      return .unavailable
    case let .descriptor(descriptor):
      guard let urls = FinderSelectionDescriptorParser.parse(descriptor) else {
        return .unavailable
      }
      return urls.isEmpty ? .empty : .selection(urls)
    }
  }

  private static func executeSelectionScript() -> FinderAppleEventResult {
    let source = "tell application \"Finder\" to return selection as alias list"
    guard let script = NSAppleScript(source: source) else {
      return .failure(-1)
    }

    var error: NSDictionary?
    let descriptor = script.executeAndReturnError(&error)
    if let number = error?[NSAppleScript.errorNumber] as? NSNumber {
      return .failure(number.intValue)
    }
    return .descriptor(descriptor)
  }
}
