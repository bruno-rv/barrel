import AppKit
import Foundation

enum FinderSelectionState: Equatable, Sendable {
  case selection([URL])
  case empty
  case unavailable
  case permissionDenied
}

enum FinderSelectionContext: Equatable, Sendable {
  case finderWasFrontmost
  case otherAppWasFrontmost

  init(frontmostBundleID: String?) {
    self = frontmostBundleID == "com.apple.finder" ? .finderWasFrontmost : .otherAppWasFrontmost
  }
}

protocol FinderSelectionReading: Sendable {
  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState
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
  private let send: (NSAppleEventDescriptor) -> FinderAppleEventResult
  private let coerce: (NSAppleEventDescriptor, DescType) -> NSAppleEventDescriptor?

  init() {
    self.init(
      send: { Self.sendSelectionEvent($0) },
      coerce: { Self.coerce($0, to: $1) }
    )
  }

  init(
    send: @escaping (NSAppleEventDescriptor) -> FinderAppleEventResult,
    coerce: @escaping (NSAppleEventDescriptor, DescType) -> NSAppleEventDescriptor?
  ) {
    self.send = send
    self.coerce = coerce
  }

  func execute() -> FinderAppleEventResult {
    guard let event = Self.selectionEvent() else {
      return .failure(errAECoercionFail)
    }

    switch send(event) {
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
              item.descriptorType == typeAlias || item.descriptorType == typeFileURL,
              let fileURL = coerce(item, typeFileURL),
              fileURL.descriptorType == typeFileURL
        else {
          return .failure(errAECoercionFail)
        }
        normalized.insert(fileURL, at: index)
      }
      return .descriptor(normalized)
    }
  }

  private static func coerce(
    _ descriptor: NSAppleEventDescriptor,
    to type: DescType
  ) -> NSAppleEventDescriptor? {
    guard let source = descriptor.aeDesc else { return nil }
    var coerced = AEDesc()
    guard AECoerceDesc(source, type, &coerced) == noErr else { return nil }
    return NSAppleEventDescriptor(aeDescNoCopy: &coerced)
  }

  private static func selectionEvent() -> NSAppleEventDescriptor? {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite),
      eventID: AEEventID(kAEGetData),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    guard let selection = selectionObjectSpecifier() else { return nil }
    event.setParam(selection, forKeyword: AEKeyword(keyDirectObject))
    event.setParam(
      NSAppleEventDescriptor(typeCode: typeAlias),
      forKeyword: AEKeyword(keyAERequestedType)
    )
    return event
  }

  private static func sendSelectionEvent(_ event: NSAppleEventDescriptor) -> FinderAppleEventResult {
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
  private let execute: @Sendable () -> FinderAppleEventResult

  init(
    execute: @escaping @Sendable () -> FinderAppleEventResult = {
      FinderAppleEventExecutor().execute()
    }
  ) {
    self.execute = execute
  }

  func readSelection(context: FinderSelectionContext) async -> FinderSelectionState {
    guard context == .finderWasFrontmost else {
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
