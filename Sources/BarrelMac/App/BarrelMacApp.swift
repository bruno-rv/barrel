import AppKit
import BarrelCore
import CoreSpotlight
import SwiftUI

@main
struct BarrelMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var syncController = SyncController()
  @StateObject private var hotKeyController = GlobalHotKeyController.shared

  var body: some Scene {
    MenuBarExtra("Barrel", systemImage: "tray") {
      ShelfMenuContent(store: appDelegate.store) {
        appDelegate.showShelf()
      }
    }

    Settings {
      SettingsView(
        store: appDelegate.store,
        syncController: syncController,
        hotKeyController: hotKeyController
      )
    }
  }
}

private struct ShelfMenuContent: View {
  @ObservedObject var store: ShelfStore
  let showShelf: () -> Void

  var body: some View {
    Button("Show Shelf", action: showShelf)

    Button("Import Files...") {
      store.importWithOpenPanel()
    }

    Button("Paste Into Shelf") {
      store.pasteFromClipboard()
    }

    Divider()

    Button("Stack Selection") {
      store.stackSelectedItems()
    }
    .disabled(store.selectedIDs.count < 2)

    Button("Delete Selection") {
      store.trashSelectedItems()
    }
    .disabled(store.selectedIDs.isEmpty)

    Divider()

    Text("\(store.liveItemCount) held items")
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = ShelfStore()
  private let hotKeyController = GlobalHotKeyController.shared
  private var shelfPanelController: ShelfPanelController?
  private var quickSendPanelController: QuickSendPanelController?
  private var observers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    ShelfWindowPreferences.migrate()
    let controller = ShelfPanelController(store: store)
    shelfPanelController = controller
    quickSendPanelController = QuickSendPanelController(store: store)
    controller.start()
    hotKeyController.start()
    observers = [
      NotificationCenter.default.addObserver(
        forName: .showBarrelQuickSend,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.quickSendPanelController?.show() }
      },
      NotificationCenter.default.addObserver(
        forName: .showBarrelShelf,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.showShelf() }
      },
      NotificationCenter.default.addObserver(
        forName: .repositoryDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.store.repositoryDidChange() }
      },
      NotificationCenter.default.addObserver(
        forName: .selectShelfItem,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let itemID = notification.object as? UUID else { return }
        Task { @MainActor in
          self?.handleSelection(itemID)
        }
      }
    ]
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    store.importURLs(urls)
  }

  func applicationWillTerminate(_ notification: Notification) {
    shelfPanelController?.stop()
    shelfPanelController = nil
    quickSendPanelController?.orderOut()
    quickSendPanelController = nil
    hotKeyController.stop()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers = []
  }

  func application(
    _ application: NSApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
  ) -> Bool {
    guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
          let itemID = UUID(uuidString: identifier) else {
      return false
    }
    handleSelection(itemID)
    return true
  }

  func showShelf() {
    shelfPanelController?.showShelf()
  }

  private func handleSelection(_ itemID: UUID) {
    store.repositoryDidChange(selecting: itemID)
    showShelf()
  }
}
