import SwiftUI

@main
struct BarrelApp: App {
  @StateObject private var store = ShelfStore()

  var body: some Scene {
    WindowGroup {
      ContentView(store: store)
        .onOpenURL { url in
          store.importURLs([url])
        }
    }
  }
}
