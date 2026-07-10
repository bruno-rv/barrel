import AppKit
import BarrelCore
import CoreSpotlight
import SwiftUI

@main
struct BarrelMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = ShelfStore()
  @StateObject private var syncController = SyncController()

  var body: some Scene {
    WindowGroup("Barrel", id: "main") {
      ContentView(store: store)
        .frame(width: 310, height: 560)
        .onAppear {
          appDelegate.configureOpenFileHandler(store: store)
        }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 310, height: 560)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Import Files...") {
          store.importWithOpenPanel()
        }
        .keyboardShortcut("i", modifiers: [.command])

        Button("Paste Into Shelf") {
          store.pasteFromClipboard()
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])

        Divider()

        Button("Stack Selection") {
          store.stackSelectedItems()
        }
        .keyboardShortcut("g", modifiers: [.command])
        .disabled(store.selectedIDs.count < 2)

        Button("Delete Selection") {
          store.trashSelectedItems()
        }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(store.selectedIDs.isEmpty)
      }
    }

    MenuBarExtra("Barrel", systemImage: "tray") {
      Button("Show Shelf") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }

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

      Text("\(store.items.count) held items")
    }

    Settings {
      SettingsView(store: store, syncController: syncController)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private weak var store: ShelfStore?
  private let hotKeyController = GlobalHotKeyController()
  private var observers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    hotKeyController.start()
    observers = [
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
        Task { @MainActor in self?.store?.repositoryDidChange() }
      },
      NotificationCenter.default.addObserver(
        forName: .selectShelfItem,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let itemID = notification.object as? UUID else { return }
        Task { @MainActor in
          self?.store?.repositoryDidChange(selecting: itemID)
          self?.showShelf()
        }
      }
    ]
  }

  func configureOpenFileHandler(store: ShelfStore) {
    self.store = store
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    store?.importURLs(urls)
  }

  func applicationWillTerminate(_ notification: Notification) {
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
    NotificationCenter.default.post(name: .selectShelfItem, object: itemID)
    return true
  }

  private func showShelf() {
    NSApp.activate(ignoringOtherApps: true)
    let shelfWindow = NSApp.windows.first { $0.title == "Barrel" } ?? NSApp.windows.first
    shelfWindow?.makeKeyAndOrderFront(nil)
  }
}
