import BarrelCore
import SwiftUI

struct SettingsView: View {
  @AppStorage("CaptureClipboardHistory") private var captureClipboardHistory = false
  @AppStorage("AutoHideShelf") private var autoHideShelf = true
  @AppStorage("ShelfEdge") private var shelfEdge = "left"

  var body: some View {
    Form {
      Picker("Shelf edge", selection: $shelfEdge) {
        Text("Left").tag("left")
        Text("Right").tag("right")
      }
      .pickerStyle(.segmented)

      Toggle("Auto-hide shelf at screen edge", isOn: $autoHideShelf)
      Toggle("Capture clipboard history", isOn: $captureClipboardHistory)
      Text("Barrel stores imported copies in Application Support and keeps original files untouched.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 420)
  }
}
