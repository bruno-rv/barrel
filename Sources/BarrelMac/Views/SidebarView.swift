import SwiftUI

struct SidebarView: View {
  @ObservedObject var store: ShelfStore

  var body: some View {
    VStack(spacing: 0) {
      filterPicker
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if store.visibleItems().isEmpty {
        EmptyShelfView(store: store)
      } else {
        List(selection: $store.selectedItemID) {
          ForEach(store.visibleItems()) { item in
            ShelfRow(
              item: item,
              isMarked: store.selectedIDs.contains(item.id)
            )
            .tag(item.id)
            .contentShape(Rectangle())
            .onTapGesture {
              store.select(item)
            }
            .onDrag {
              store.itemProvider(for: item)
            }
            .contextMenu {
              Button("Mark for Stack") {
                store.toggleSelection(for: item)
              }
              if item.isStack {
                Button("Split Stack") {
                  store.splitStack(item)
                }
              }
              Button("Reveal in Finder") {
                store.reveal(item)
              }
              Button("Open") {
                store.open(item)
              }
              Divider()
              Button("Delete", role: .destructive) {
                store.delete(item)
              }
            }
          }
        }
        .listStyle(.sidebar)
      }
    }
    .searchable(text: $store.searchText, placement: .sidebar)
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
