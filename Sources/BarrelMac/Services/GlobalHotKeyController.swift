import Carbon.HIToolbox
import Combine
import Foundation

extension Notification.Name {
  static let showBarrelShelf = Notification.Name("showBarrelShelf")
  static let showBarrelQuickSend = Notification.Name("showBarrelQuickSend")
  static let selectShelfItem = Notification.Name("selectShelfItem")
  static let repositoryDidChange = Notification.Name("repositoryDidChange")
}

enum GlobalHotKeyAction: UInt32, CaseIterable, Sendable {
  case shelf = 1
  case quickSend = 2

  var title: String {
    switch self {
    case .shelf: "Shelf"
    case .quickSend: "Quick Send"
    }
  }

  var enabledKey: String {
    switch self {
    case .shelf: "GlobalHotKeyEnabled"
    case .quickSend: "QuickSendHotKeyEnabled"
    }
  }

  var choiceKey: String {
    switch self {
    case .shelf: "GlobalHotKeyChoice"
    case .quickSend: "QuickSendHotKeyChoice"
    }
  }
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

protocol GlobalHotKeyRegistering {
  func register(action: GlobalHotKeyAction, choice: GlobalHotKeyChoice) -> (OSStatus, EventHotKeyRef?)
  func unregister(_ hotKey: EventHotKeyRef)
}

private struct CarbonGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
  func register(action: GlobalHotKeyAction, choice: GlobalHotKeyChoice) -> (OSStatus, EventHotKeyRef?) {
    let identifier = EventHotKeyID(signature: 0x4252_524C, id: action.rawValue)
    var hotKey: EventHotKeyRef?
    let status = RegisterEventHotKey(
      choice.keyCode,
      choice.modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    return (status, hotKey)
  }

  func unregister(_ hotKey: EventHotKeyRef) {
    UnregisterEventHotKey(hotKey)
  }
}

@MainActor
final class GlobalHotKeyController: ObservableObject {
  static let shared = GlobalHotKeyController()

  @Published private var registrationErrors: [GlobalHotKeyAction: String] = [:]

  var registrationError: String? { registrationError(for: .shelf) }

  private let defaults: UserDefaults
  private let registrar: any GlobalHotKeyRegistering
  private let notificationCenter: NotificationCenter
  private var eventHandler: EventHandlerRef?
  private var hotKeys: [GlobalHotKeyAction: EventHotKeyRef] = [:]
  private var defaultsObserver: NSObjectProtocol?

  init(
    defaults: UserDefaults = .standard,
    registrar: any GlobalHotKeyRegistering = CarbonGlobalHotKeyRegistrar(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.defaults = defaults
    self.registrar = registrar
    self.notificationCenter = notificationCenter
  }

  func registrationError(for action: GlobalHotKeyAction) -> String? {
    registrationErrors[action]
  }

  func start() {
    guard eventHandler == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        guard let event, let userData else { return noErr }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &identifier
        )
        guard status == noErr else { return status }
        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
          controller.handleHotKeyID(identifier.id)
        }
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard status == noErr else {
      eventHandler = nil
      registrationErrors[.shelf] = "Could not install the shortcut handler (OSStatus \(status))."
      registrationErrors[.quickSend] = "Could not install the shortcut handler (OSStatus \(status))."
      return
    }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: defaults,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.configureHotKeys()
      }
    }
    configureHotKeys()
  }

  func stop() {
    unregisterHotKeys()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
      self.defaultsObserver = nil
    }
  }

  func configureHotKeys() {
    unregisterHotKeys()
    registrationErrors.removeAll()

    var configuredChoices: [GlobalHotKeyAction: GlobalHotKeyChoice] = [:]
    for action in GlobalHotKeyAction.allCases where defaults.bool(forKey: action.enabledKey) {
      guard let storedChoice = defaults.string(forKey: action.choiceKey),
            let choice = GlobalHotKeyChoice(rawValue: storedChoice) else {
        registrationErrors[action] = "The saved \(action.title) shortcut is invalid."
        continue
      }
      configuredChoices[action] = choice
    }

    if let shelfChoice = configuredChoices[.shelf], configuredChoices[.quickSend] == shelfChoice {
      configuredChoices[.quickSend] = nil
      registrationErrors[.quickSend] = "Quick Send shortcut conflicts with the Shelf shortcut."
    }

    for action in GlobalHotKeyAction.allCases {
      guard let choice = configuredChoices[action] else { continue }
      let (status, hotKey) = registrar.register(action: action, choice: choice)
      guard status == noErr, let hotKey else {
        registrationErrors[action] = "\(action.title) shortcut could not be registered (OSStatus \(status))."
        continue
      }
      hotKeys[action] = hotKey
    }
  }

  func handleHotKeyID(_ rawValue: UInt32) {
    guard let action = GlobalHotKeyAction(rawValue: rawValue) else { return }
    switch action {
    case .shelf:
      notificationCenter.post(name: .showBarrelShelf, object: nil)
    case .quickSend:
      notificationCenter.post(name: .showBarrelQuickSend, object: nil)
    }
  }

  private func unregisterHotKeys() {
    for hotKey in hotKeys.values {
      registrar.unregister(hotKey)
    }
    hotKeys.removeAll()
  }
}
