import Foundation

enum ShelfWindowPreferences {
  static let edgeKey = "ShelfEdge"
  static let autoHideKey = "AutoHideShelf"
  static let migrationKey = "ShelfWindowBehaviorVersion"
  static let currentVersion = 1

  static func migrate(_ defaults: UserDefaults = .standard) {
    guard defaults.integer(forKey: migrationKey) < currentVersion else {
      return
    }
    defaults.set(ShelfEdge.left.rawValue, forKey: edgeKey)
    defaults.set(true, forKey: autoHideKey)
    defaults.set(currentVersion, forKey: migrationKey)
  }
}
