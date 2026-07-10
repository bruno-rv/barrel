import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: ShelfStore
  @AppStorage("CaptureClipboardHistory") private var captureClipboardHistory = false
  @AppStorage("ClipboardLifetimeHours") private var clipboardLifetimeHours = 24
  @AppStorage("StorageQuotaBytes") private var storageQuotaBytes = 1_073_741_824
  @AppStorage("AutoHideShelf") private var autoHideShelf = true
  @AppStorage("ShelfEdge") private var shelfEdge = "left"
  @AppStorage("GlobalHotKeyEnabled") private var globalHotKeyEnabled = true
  @AppStorage("GlobalHotKeyChoice") private var globalHotKeyChoice = GlobalHotKeyChoice.controlOptionSpace.rawValue

  var body: some View {
    Form {
      Section("Shelf") {
        Picker("Shelf edge", selection: $shelfEdge) {
          Text("Left").tag("left")
          Text("Right").tag("right")
        }
        .pickerStyle(.segmented)

        Toggle("Auto-hide shelf at screen edge", isOn: $autoHideShelf)
      }

      Section("Clipboard Privacy") {
        Toggle("Capture clipboard history", isOn: $captureClipboardHistory)
        Picker("Automatic capture lifetime", selection: $clipboardLifetimeHours) {
          Text("1 hour").tag(1)
          Text("24 hours").tag(24)
          Text("1 week").tag(168)
        }
        .disabled(!captureClipboardHistory)

        Text("Clipboard capture is off by default. When enabled, Barrel copies supported clipboard content into its private Application Support folder and expires it after the selected lifetime unless pinned.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("Global Shortcut") {
        Toggle("Enable global shelf shortcut", isOn: $globalHotKeyEnabled)
        Picker("Shortcut", selection: $globalHotKeyChoice) {
          ForEach(GlobalHotKeyChoice.allCases) { choice in
            Text(choice.label).tag(choice.rawValue)
          }
        }
        .disabled(!globalHotKeyEnabled)
      }

      Section("Storage") {
        Picker("Storage quota", selection: $storageQuotaBytes) {
          Text("256 MB").tag(268_435_456)
          Text("512 MB").tag(536_870_912)
          Text("1 GB").tag(1_073_741_824)
          Text("2 GB").tag(2_147_483_648)
        }
        Text("Using \(formattedStorageUsage)")
          .foregroundStyle(.secondary)
        Button("Clean Up Now") {
          store.cleanup()
        }

        Text("Cleanup expires unpinned items first, then removes the oldest automatic clipboard captures. Deliberate imports are never selected solely to satisfy the quota.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Text("Barrel stores imported copies in Application Support and keeps original files untouched. Deleted items remain recoverable in Trash until emptied or removed after seven days.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 460)
    .onAppear {
      store.setClipboardCapture(enabled: captureClipboardHistory)
      store.setStorageQuota(storageQuotaBytes)
    }
    .onChange(of: captureClipboardHistory) {
      store.setClipboardCapture(enabled: captureClipboardHistory)
    }
    .onChange(of: storageQuotaBytes) {
      store.setStorageQuota(storageQuotaBytes)
    }
  }

  private var formattedStorageUsage: String {
    ByteCountFormatter.string(fromByteCount: store.storageUsage, countStyle: .file)
  }
}

#Preview {
  SettingsView(store: .preview)
}
