import Carbon.HIToolbox
import XCTest
@testable import BarrelMac

@MainActor
final class GlobalHotKeyControllerTests: XCTestCase {
  private final class Registrar: GlobalHotKeyRegistering {
    struct Registration: Equatable {
      let action: GlobalHotKeyAction
      let choice: GlobalHotKeyChoice
    }

    var registered: [Registration] = []
    var unregistered: [EventHotKeyRef] = []
    var failingActions: Set<GlobalHotKeyAction> = []

    func register(action: GlobalHotKeyAction, choice: GlobalHotKeyChoice) -> (OSStatus, EventHotKeyRef?) {
      registered.append(Registration(action: action, choice: choice))
      guard !failingActions.contains(action) else { return (-1, nil) }
      return (noErr, EventHotKeyRef(bitPattern: Int(action.rawValue)))
    }

    func unregister(_ hotKey: EventHotKeyRef) {
      unregistered.append(hotKey)
    }
  }

  private var suiteName: String!
  private var defaults: UserDefaults!
  private var registrar: Registrar!
  private var notificationCenter: NotificationCenter!
  private var controller: GlobalHotKeyController!

  override func setUp() {
    super.setUp()
    suiteName = "GlobalHotKeyControllerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: "GlobalHotKeyEnabled")
    defaults.set(GlobalHotKeyChoice.controlOptionSpace.rawValue, forKey: "GlobalHotKeyChoice")
    defaults.set(true, forKey: "QuickSendHotKeyEnabled")
    defaults.set(GlobalHotKeyChoice.controlShiftSpace.rawValue, forKey: "QuickSendHotKeyChoice")
    registrar = Registrar()
    notificationCenter = NotificationCenter()
    controller = GlobalHotKeyController(
      defaults: defaults,
      registrar: registrar,
      notificationCenter: notificationCenter
    )
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testRegistersAndDispatchesBothActionsWithStableIDs() {
    controller.configureHotKeys()

    XCTAssertEqual(registrar.registered.map(\.action), [.shelf, .quickSend])
    XCTAssertEqual(GlobalHotKeyAction.shelf.rawValue, 1)
    XCTAssertEqual(GlobalHotKeyAction.quickSend.rawValue, 2)

    var notifications: [Notification.Name] = []
    let shelf = notificationCenter.addObserver(forName: .showBarrelShelf, object: nil, queue: nil) { note in
      notifications.append(note.name)
    }
    let quickSend = notificationCenter.addObserver(forName: .showBarrelQuickSend, object: nil, queue: nil) { note in
      notifications.append(note.name)
    }
    defer {
      notificationCenter.removeObserver(shelf)
      notificationCenter.removeObserver(quickSend)
    }

    controller.handleHotKeyID(GlobalHotKeyAction.shelf.rawValue)
    XCTAssertEqual(notifications, [.showBarrelShelf])
    controller.handleHotKeyID(GlobalHotKeyAction.quickSend.rawValue)
    XCTAssertEqual(notifications, [.showBarrelShelf, .showBarrelQuickSend])
  }

  func testEnablementIsIndependent() {
    defaults.set(false, forKey: "GlobalHotKeyEnabled")
    controller.configureHotKeys()
    XCTAssertEqual(registrar.registered.map(\.action), [.quickSend])

    registrar.registered.removeAll()
    defaults.set(true, forKey: "GlobalHotKeyEnabled")
    defaults.set(false, forKey: "QuickSendHotKeyEnabled")
    controller.configureHotKeys()
    XCTAssertEqual(registrar.registered.map(\.action), [.shelf])
  }

  func testShelfWinsSameChoiceConflict() {
    defaults.set(GlobalHotKeyChoice.controlOptionSpace.rawValue, forKey: "QuickSendHotKeyChoice")
    controller.configureHotKeys()

    XCTAssertEqual(registrar.registered.map(\.action), [.shelf])
    XCTAssertNil(controller.registrationError(for: .shelf))
    XCTAssertEqual(controller.registrationError(for: .quickSend), "Quick Send shortcut conflicts with the Shelf shortcut.")
  }

  func testInvalidSavedValuesDoNotSilentlyFallback() {
    defaults.set("invalid-shelf", forKey: "GlobalHotKeyChoice")
    defaults.set("invalid-quick-send", forKey: "QuickSendHotKeyChoice")
    controller.configureHotKeys()

    XCTAssertTrue(registrar.registered.isEmpty)
    XCTAssertEqual(controller.registrationError(for: .shelf), "The saved Shelf shortcut is invalid.")
    XCTAssertEqual(controller.registrationError(for: .quickSend), "The saved Quick Send shortcut is invalid.")
  }

  func testOneRegistrationFailureDoesNotRemoveOtherAction() {
    registrar.failingActions = [.quickSend]
    controller.configureHotKeys()

    XCTAssertEqual(registrar.registered.map(\.action), [.shelf, .quickSend])
    XCTAssertNil(controller.registrationError(for: .shelf))
    XCTAssertEqual(controller.registrationError(for: .quickSend), "Quick Send shortcut could not be registered (OSStatus -1).")
  }

  func testReconfigurationUnregistersEveryExistingRegistration() {
    controller.configureHotKeys()
    controller.configureHotKeys()

    XCTAssertEqual(registrar.unregistered.count, 2)
    XCTAssertEqual(registrar.registered.map(\.action), [.shelf, .quickSend, .shelf, .quickSend])
  }
}
