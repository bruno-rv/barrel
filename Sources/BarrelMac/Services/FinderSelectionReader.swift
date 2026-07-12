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
            item.descriptorType == typeFileURL,
            let url = item.fileURLValue
      else {
        return nil
      }
      urls.append(url)
    }
    return urls
  }
}

struct FinderAppleEventExecutor: @unchecked Sendable {
  private let send: () -> FinderAppleEventResult
  private let coerceToFileURL: (NSAppleEventDescriptor) -> NSAppleEventDescriptor?

  init() {
    self.init(
      send: { Self.sendSelectionEvent() },
      coerceToFileURL: { Self.coerceToFileURL($0) }
    )
  }

  init(
    send: @escaping () -> FinderAppleEventResult,
    coerceToFileURL: @escaping (NSAppleEventDescriptor) -> NSAppleEventDescriptor?
  ) {
    self.send = send
    self.coerceToFileURL = coerceToFileURL
  }

  func execute() -> FinderAppleEventResult {
    switch send() {
    case let .failure(error):
      return .failure(error)
    case let .descriptor(raw):
      guard raw.descriptorType == typeAEList else {
        return .failure(errAECoercionFail)
      }

      let normalized = NSAppleEventDescriptor.list()
      for offset in 0..<raw.numberOfItems {
        let index = offset + 1
        guard let item = raw.atIndex(index),
              let fileURL = coerceToFileURL(item),
              fileURL.descriptorType == typeFileURL
        else {
          return .failure(errAECoercionFail)
        }
        normalized.insert(fileURL, at: index)
      }
      return .descriptor(normalized)
    }
  }

  private static func coerceToFileURL(_ descriptor: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
    guard let source = descriptor.aeDesc else { return nil }
    var coerced = AEDesc()
    guard AECoerceDesc(source, typeFileURL, &coerced) == noErr else { return nil }
    return NSAppleEventDescriptor(aeDescNoCopy: &coerced)
  }

  private static func sendSelectionEvent() -> FinderAppleEventResult {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite),
      eventID: AEEventID(kAEGetData),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    guard let selection = selectionObjectSpecifier() else {
      return .failure(errAECoercionFail)
    }
    event.setParam(selection, forKeyword: AEKeyword(keyDirectObject))

    guard let eventDesc = event.aeDesc else {
      return .failure(errAEEventNotHandled)
    }
    var reply = AppleEvent()
    let status = AESendMessage(
      eventDesc,
      &reply,
      AESendMode(kAEWaitReply | kAECanInteract),
      kAEDefaultTimeout
    )
    guard status == noErr else { return .failure(Int(status)) }
    defer { AEDisposeDesc(&reply) }

    var errorNumber: Int32 = 0
    var actualType = DescType(typeNull)
    var actualSize = 0
    if AEGetParamPtr(
      &reply,
      AEKeyword(keyErrorNumber),
      DescType(typeSInt32),
      &actualType,
      &errorNumber,
      MemoryLayout<Int32>.size,
      &actualSize
    ) == noErr, errorNumber != 0 {
      return .failure(Int(errorNumber))
    }

    var result = AEDesc()
    let resultStatus = AEGetParamDesc(
      &reply,
      AEKeyword(keyDirectObject),
      DescType(typeWildCard),
      &result
    )
    guard resultStatus == noErr else { return .failure(Int(resultStatus)) }
    return .descriptor(NSAppleEventDescriptor(aeDescNoCopy: &result))
  }

  private static func selectionObjectSpecifier() -> NSAppleEventDescriptor? {
    let selectionProperty = OSType(0x73656C65) // 'sele'
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(
      NSAppleEventDescriptor(typeCode: typeProperty),
      forKeyword: AEKeyword(keyAEDesiredClass)
    )
    record.setDescriptor(
      NSAppleEventDescriptor(enumCode: OSType(formPropertyID)),
      forKeyword: AEKeyword(keyAEKeyForm)
    )
    record.setDescriptor(
      NSAppleEventDescriptor(typeCode: selectionProperty),
      forKeyword: AEKeyword(keyAEKeyData)
    )
    record.setDescriptor(
      NSAppleEventDescriptor.null(),
      forKeyword: AEKeyword(keyAEContainer)
    )

    guard let source = record.aeDesc else { return nil }
    var objectSpecifier = AEDesc()
    guard AECoerceDesc(source, typeObjectSpecifier, &objectSpecifier) == noErr else { return nil }
    return NSAppleEventDescriptor(aeDescNoCopy: &objectSpecifier)
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
      FinderAppleEventExecutor().execute()
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
}
