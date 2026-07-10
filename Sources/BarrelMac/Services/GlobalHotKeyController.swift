import Carbon.HIToolbox
import Foundation

extension Notification.Name {
  static let showBarrelShelf = Notification.Name("showBarrelShelf")
  static let selectShelfItem = Notification.Name("selectShelfItem")
  static let repositoryDidChange = Notification.Name("repositoryDidChange")
}

enum GlobalHotKeyChoice: String, CaseIterable, Identifiable {
  case controlOptionSpace = "control-option-space"
  case controlShiftSpace = "control-shift-space"
  case commandOptionB = "command-option-b"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .controlOptionSpace: "Control–Option–Space"
    case .controlShiftSpace: "Control–Shift–Space"
    case .commandOptionB: "Command–Option–B"
    }
  }

  fileprivate var keyCode: UInt32 {
    switch self {
    case .controlOptionSpace, .controlShiftSpace: UInt32(kVK_Space)
    case .commandOptionB: UInt32(kVK_ANSI_B)
    }
  }

  fileprivate var modifiers: UInt32 {
    switch self {
    case .controlOptionSpace: UInt32(controlKey | optionKey)
    case .controlShiftSpace: UInt32(controlKey | shiftKey)
    case .commandOptionB: UInt32(cmdKey | optionKey)
    }
  }
}

@MainActor
final class GlobalHotKeyController {
  private let defaults: UserDefaults
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?
  private var defaultsObserver: NSObjectProtocol?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func start() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
          controller.hotKeyPressed()
        }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: defaults,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.registerConfiguredHotKey()
      }
    }
    registerConfiguredHotKey()
  }

  func stop() {
    unregisterHotKey()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
      self.defaultsObserver = nil
    }
  }

  private func registerConfiguredHotKey() {
    unregisterHotKey()
    guard defaults.bool(forKey: "GlobalHotKeyEnabled") else { return }
    let storedChoice = defaults.string(forKey: "GlobalHotKeyChoice") ?? ""
    let choice = GlobalHotKeyChoice(rawValue: storedChoice) ?? .controlOptionSpace
    let identifier = EventHotKeyID(signature: 0x4252_524C, id: 1)
    RegisterEventHotKey(
      choice.keyCode,
      choice.modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
  }

  private func unregisterHotKey() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
  }

  private func hotKeyPressed() {
    NotificationCenter.default.post(name: .showBarrelShelf, object: nil)
  }
}
