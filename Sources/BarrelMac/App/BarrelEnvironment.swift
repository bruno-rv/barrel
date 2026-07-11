import BarrelCore
import Foundation

final class BarrelEnvironment {
  static let shared = BarrelEnvironment()

  let repository: ShelfRepository

  private init(fileManager: FileManager = .default, defaults: UserDefaults = .standard) {
    defaults.register(defaults: [
      "CaptureClipboardHistory": false,
      "ClipboardLifetimeHours": 24,
      "StorageQuotaBytes": 1_073_741_824,
      "GlobalHotKeyEnabled": true,
      "GlobalHotKeyChoice": "control-option-space",
      "CloudSyncEnabled": false
    ])
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let rootURL = base.appendingPathComponent("BarrelMac", isDirectory: true)
    let deviceID: String
    if let existing = defaults.string(forKey: "BarrelDeviceID") {
      deviceID = existing
    } else {
      deviceID = UUID().uuidString
      defaults.set(deviceID, forKey: "BarrelDeviceID")
    }
    repository = ShelfRepository(
      configuration: RepositoryConfiguration(
        rootURL: rootURL,
        deviceID: deviceID,
        quotaBytes: Int64(defaults.integer(forKey: "StorageQuotaBytes"))
      )
    )
  }
}
