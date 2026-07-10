import AppKit
import BarrelCore
import SwiftUI

@main
struct BarrelMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = ShelfStore()

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
      SettingsView()
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private weak var store: ShelfStore?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func configureOpenFileHandler(store: ShelfStore) {
    self.store = store
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    store?.importURLs(urls)
  }
}
