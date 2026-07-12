import BarrelCore
import SwiftUI

struct SidebarView: View {
  @ObservedObject var store: ShelfStore

  var body: some View {
    VStack(spacing: 0) {
      filterPicker
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if store.visibleItems.isEmpty {
        EmptyShelfView(store: store)
      } else {
        List(selection: $store.selectedItemID) {
          ForEach(store.visibleItems) { item in
            itemRow(item)
            .tag(item.id)
            .contentShape(Rectangle())
            .onTapGesture {
              store.select(item)
            }
            .contextMenu {
              if item.trashedAt != nil {
                Button("Restore") { store.restore(item) }
                Button("Delete Permanently", role: .destructive) {
                  store.deletePermanently(item)
                }
              } else {
                Button("Mark for Stack") { store.toggleSelection(for: item) }
                if item.isStack {
                  Button("Split Stack") { store.splitStack(item) }
                }
                Button(item.isPinned ? "Unpin" : "Pin") {
                  store.setPinned(item, isPinned: !item.isPinned)
                }
                Menu("Expiration") {
                  Button("One Hour") { store.setExpiration(item, preset: .oneHour) }
                  Button("One Day") { store.setExpiration(item, preset: .oneDay) }
                  Button("One Week") { store.setExpiration(item, preset: .oneWeek) }
                  Button("Never") { store.setExpiration(item, preset: .never) }
                }
                Button("Reveal in Finder") { store.reveal(item) }
                Button("Open") { store.open(item) }
                Divider()
                Button("Move to Trash", role: .destructive) { store.trash(item) }
              }
            }
          }
        }
        .listStyle(.sidebar)
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar)
  }

  @ViewBuilder
  private func itemRow(_ item: ShelfItem) -> some View {
    if item.kind == .file || item.kind == .image {
      FilePromiseDragSource(
        itemID: item.id,
        fileName: item.fileName ?? item.title,
        exporter: store
      ) {
        ShelfRow(item: item, isMarked: store.selectedIDs.contains(item.id))
      }
    } else {
      ShelfRow(item: item, isMarked: store.selectedIDs.contains(item.id))
        .onDrag { store.itemProvider(for: item) }
    }
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $store.filter) {
      ForEach(ShelfFilter.allCases) { filter in
        Label(filter.label, systemImage: filter.systemImage)
          .tag(filter)
      }
    }
    .pickerStyle(.segmented)
  }
}

private struct ShelfRow: View {
  let item: ShelfItem
  let isMarked: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.kind.systemImage)
        .foregroundStyle(Color.accentColor)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.body)
          .lineLimit(1)

        Text(item.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if isMarked {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Color.accentColor)
      } else if item.isPinned {
        Image(systemName: "pin.fill")
          .foregroundStyle(.secondary)
      } else if item.expiresAt != nil {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
      } else if item.isStack {
        Text("\(item.children.count)")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct EmptyShelfView: View {
  @ObservedObject var store: ShelfStore

  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)
      Text("Shelf Empty")
        .font(.headline)
      Text("Import, paste, or drop items here.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
    .padding()
  }
}
