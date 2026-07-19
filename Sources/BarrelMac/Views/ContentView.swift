import AppKit
import BarrelCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var store: ShelfStore
  let onDropTargetChange: (Bool) -> Void
  @AppStorage("CaptureClipboardHistory") private var captureClipboardHistory = false
  @State private var isDropTargeted = false

  init(
    store: ShelfStore,
    onDropTargetChange: @escaping (Bool) -> Void = { _ in }
  ) {
    self.store = store
    self.onDropTargetChange = onDropTargetChange
  }

  var body: some View {
    ZStack {
      panelBackground

      VStack(spacing: 10) {
        header
        searchAndFilters

        if store.viewMode == .history {
          history
        } else if store.visibleItems.isEmpty {
          emptyShelf
        } else {
          shelfItems
        }

        footer
      }
      .padding(12)

      if isDropTargeted {
        DropOverlay()
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .onDrop(
      of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier, UTType.image.identifier],
      isTargeted: $isDropTargeted
    ) { providers in
      store.importProviders(providers)
      return true
    }
    .onChange(of: isDropTargeted) {
      onDropTargetChange(isDropTargeted)
    }
    .onDisappear {
      onDropTargetChange(false)
    }
    .onAppear {
      store.setClipboardCapture(enabled: captureClipboardHistory)
    }
    .onChange(of: captureClipboardHistory) {
      store.setClipboardCapture(enabled: captureClipboardHistory)
    }
    .alert("Barrel could not finish that action", isPresented: errorBinding) {
      Button("OK") {
        store.errorMessage = nil
      }
    } message: {
      Text(store.errorMessage ?? "")
    }
    .background {
      Button("Select All") {
        store.selectAllVisibleItems()
      }
      .keyboardShortcut("a", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  private var panelBackground: some View {
    LinearGradient(
      colors: [
        Color(red: 0.24, green: 0.13, blue: 0.34).opacity(0.92),
        Color(red: 0.38, green: 0.22, blue: 0.50).opacity(0.90),
        Color(red: 0.21, green: 0.16, blue: 0.31).opacity(0.94)
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay(.ultraThinMaterial.opacity(0.28))
    .ignoresSafeArea()
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 1) {
        Text("Barrel")
          .font(.headline.weight(.bold))
          .foregroundStyle(.white)
        Text("\(store.liveItemCount) held items")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.62))
      }

      Spacer()

      Button {
        store.importWithOpenPanel()
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white)
      .help("Import files")
    }
  }

  private var searchAndFilters: some View {
    VStack(spacing: 8) {
      HStack(spacing: 6) {
        modeButton("Bucket", image: "tray.full", mode: .bucket, action: store.openBucket)
        modeButton("History", image: "clock.arrow.circlepath", mode: .history) {
          Task { await store.openHistory() }
        }
        modeButton("Trash", image: "trash", mode: .trash, action: store.openTrash)
      }

      if store.viewMode == .bucket {
        TextField("Search shelf", text: $store.searchText)
          .textFieldStyle(.roundedBorder)

        HStack(spacing: 6) {
          ForEach([ShelfFilter.all, .files, .images, .links, .text, .stacks]) { filter in
            Button {
              store.filter = filter
            } label: {
              Image(systemName: filter.systemImage)
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.filter == filter ? .white : .white.opacity(0.55))
            .background(
              Capsule()
                .fill(store.filter == filter ? Color.white.opacity(0.18) : Color.clear)
            )
            .help(filter.label)
          }
        }
      }
    }
  }

  private func modeButton(
    _ title: String,
    image: String,
    mode: ShelfViewMode,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: image)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(store.viewMode == mode ? Color.white.opacity(0.18) : Color.clear)
    )
  }

  private var history: some View {
    Group {
      if store.historyEvents.isEmpty {
        VStack {
          Spacer()
          Text("Files moved to Finder appear here for 24 hours.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.58))
          Spacer()
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(store.historyEvents) { event in
              HistoryEventRow(event: event, canUndo: store.isUndoEligible(event)) {
                store.undo(event)
              }
              .padding(8)
              .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
      }
    }
    .foregroundStyle(.white)
  }

  private var shelfItems: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(store.visibleItems) { item in
          ShelfTile(
            item: item,
            isReadOnlyOverlay: store.isReadOnlyOverlay(item),
            isSelected: store.selectedItemID == item.id,
            isMarked: store.selectedIDs.contains(item.id),
            fileURL: store.fileURL(for: item),
            select: {
              let flags = NSEvent.modifierFlags
              store.select(
                item,
                shift: flags.contains(.shift),
                command: flags.contains(.command)
              )
            },
            toggleMark: { store.toggleSelection(for: item) },
            open: { store.open(item) },
            reveal: { store.reveal(item) },
            split: { store.splitStack(item) },
            pin: { store.setPinned(item, isPinned: !item.isPinned) },
            expire: { store.setExpiration(item, preset: $0) },
            trash: { store.trash(item) },
            restore: { store.restore(item) },
            deletePermanently: { store.deletePermanently(item) },
            filePromiseExporter: store,
            itemProvider: { store.itemProvider(for: item) }
          )
        }
      }
      .padding(.vertical, 2)
    }
  }

  private var emptyShelf: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "tray.and.arrow.down")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.white.opacity(0.72))
      Text("Drop anything here")
        .font(.headline)
        .foregroundStyle(.white)
      Text("Files, text, links, images, and clipboard copies.")
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.58))
        .frame(maxWidth: 210)
      HStack {
        Button("Import") {
          store.importWithOpenPanel()
        }
        Button("Paste") {
          store.pasteFromClipboard()
        }
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button {
        store.pasteFromClipboard()
      } label: {
        Image(systemName: "doc.on.clipboard")
      }
      .help("Paste into shelf")

      if store.viewMode == .trash {
        Button(role: .destructive) {
          store.emptyTrash()
        } label: {
          Image(systemName: "trash.slash")
        }
        .help("Empty Trash")
      } else if store.viewMode == .bucket {
        Button {
          store.selectAllVisibleItems()
        } label: {
          Image(systemName: "checklist")
        }
        .disabled(store.visibleItems.isEmpty)
        .help("Select all items (⌘A)")

        Button {
          store.stackSelectedItems()
        } label: {
          Image(systemName: "square.stack.3d.up")
        }
        .disabled(store.selectedIDs.count < 2)
        .help("Stack marked items")

        Button(role: .destructive) {
          store.trashSelectedItems()
        } label: {
          Image(systemName: "trash")
        }
        .disabled(store.selectedIDs.isEmpty)
        .help("Move marked items to Trash")
      }

      Spacer()
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.white)
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          store.errorMessage = nil
        }
      }
    )
  }
}

private struct ShelfTile: View {
  let item: ShelfItem
  let isReadOnlyOverlay: Bool
  let isSelected: Bool
  let isMarked: Bool
  let fileURL: URL?
  let select: () -> Void
  let toggleMark: () -> Void
  let open: () -> Void
  let reveal: () -> Void
  let split: () -> Void
  let pin: () -> Void
  let expire: (ShelfExpirationPreset) -> Void
  let trash: () -> Void
  let restore: () -> Void
  let deletePermanently: () -> Void
  let filePromiseExporter: any ShelfFilePromiseExporting
  let itemProvider: () -> NSItemProvider

  @ViewBuilder
  var body: some View {
    if item.kind == .file || item.kind == .image {
      FilePromiseDragSource(
        itemID: item.id,
        fileName: item.fileName ?? item.title,
        exporter: filePromiseExporter
      ) {
        tile
      }
    } else {
      tile.onDrag(itemProvider)
    }
  }

  private var tile: some View {
    HStack(spacing: 10) {
      thumbnail

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)

        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.58))
          .lineLimit(1)

        if item.isPinned {
          Label("Pinned", systemImage: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.72))
        } else if let expiresAt = item.expiresAt {
          Text("Expires \(expiresAt, style: .relative)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.72))
        }
      }

      Spacer(minLength: 8)

      if item.trashedAt == nil && !isReadOnlyOverlay {
        Button(action: toggleMark) {
          Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isMarked ? .white : .white.opacity(0.42))
        }
        .buttonStyle(.plain)
        .help("Toggle selection (⌘-click)")
      }
    }
    .padding(8)
    .background(tileBackground, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isSelected ? Color.white.opacity(0.34) : Color.white.opacity(0.08))
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: open)
    .onTapGesture(perform: select)
    .contextMenu {
      if item.trashedAt != nil {
        Button("Restore", action: restore)
        Button("Delete Permanently", role: .destructive, action: deletePermanently)
      } else {
        if !isReadOnlyOverlay {
          Button(isMarked ? "Deselect" : "Select", action: toggleMark)
        }
        Button("Open", action: open)
        if fileURL != nil {
          Button("Reveal in Finder", action: reveal)
        }
        if !isReadOnlyOverlay {
          if item.isStack {
            Button("Split Stack", action: split)
          }
          Button(item.isPinned ? "Unpin" : "Pin", action: pin)
          Menu("Expiration") {
            Button("One Hour") { expire(.oneHour) }
            Button("One Day") { expire(.oneDay) }
            Button("One Week") { expire(.oneWeek) }
            Button("Never") { expire(.never) }
          }
          Divider()
          Button("Move to Trash", role: .destructive, action: trash)
        }
      }
    }
  }

  @ViewBuilder
  private var thumbnail: some View {
    if item.kind == .image, let fileURL {
      CachedThumbnailView(url: fileURL, itemID: item.id, maxPixelSize: 76)
        .scaledToFill()
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    } else {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 7)
          .fill(iconColor)
          .frame(width: 38, height: 38)
        Image(systemName: item.kind.systemImage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)

        if item.isStack {
          Text("\(item.children.count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .background(.black.opacity(0.28), in: Capsule())
            .offset(x: 5, y: 5)
        }
      }
    }
  }

  private var tileBackground: some ShapeStyle {
    isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.10)
  }

  private var iconColor: Color {
    switch item.kind {
    case .file: Color.blue
    case .image: Color.teal
    case .link: Color.orange
    case .text: Color.pink
    case .stack: Color.indigo
    }
  }
}

private struct DropOverlay: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 16)
      .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
      .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        VStack(spacing: 8) {
          Image(systemName: "arrow.down.to.line.compact")
            .font(.system(size: 26, weight: .bold))
          Text("Hold in Barrel")
            .font(.headline)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(16)
      .allowsHitTesting(false)
  }
}

#Preview {
  ContentView(store: .preview)
    .frame(width: 280, height: 480)
}
