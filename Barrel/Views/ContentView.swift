import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var store: ShelfStore
  @State private var isImporterPresented = false
  @State private var isDropTargeted = false
  @State private var selectedDetail: ShelfDetailSelection?
  @State private var editMode: EditMode = .inactive

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        filterBar

        ZStack {
          if store.visibleItems().isEmpty {
            EmptyShelfView(importAction: { isImporterPresented = true }, pasteAction: store.pasteFromClipboard)
          } else {
            shelfList
          }

          if isDropTargeted {
            DropOverlay()
          }
        }
      }
      .navigationTitle("Barrel")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          if editMode.isEditing, !store.selectedIDs.isEmpty {
            Button {
              store.stackSelectedItems()
            } label: {
              Label("Stack", systemImage: "square.stack.3d.up")
            }
            .disabled(store.selectedIDs.count < 2)

            Button(role: .destructive) {
              store.deleteSelectedItems()
              editMode = .inactive
            } label: {
              Label("Delete", systemImage: "trash")
            }
          }

          Button {
            store.pasteFromClipboard()
          } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
          }

          Button {
            isImporterPresented = true
          } label: {
            Label("Import", systemImage: "tray.and.arrow.down")
          }

          EditButton()
        }
      }
      .environment(\.editMode, $editMode)
      .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always))
      .fileImporter(
        isPresented: $isImporterPresented,
        allowedContentTypes: [.item, .data, .content, .text, .url, .image],
        allowsMultipleSelection: true
      ) { result in
        switch result {
        case .success(let urls):
          store.importURLs(urls)
        case .failure(let error):
          store.errorMessage = error.localizedDescription
        }
      }
      .onDrop(
        of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.text.identifier, UTType.image.identifier],
        isTargeted: $isDropTargeted,
        perform: { providers in
          store.importProviders(providers)
          return true
        }
      )
      .sheet(item: $selectedDetail) { selection in
        ShelfDetailView(store: store, itemID: selection.id)
      }
      .alert("Barrel could not finish that action", isPresented: errorBinding) {
        Button("OK", role: .cancel) {
          store.errorMessage = nil
        }
      } message: {
        Text(store.errorMessage ?? "")
      }
    }
  }

  private var filterBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(ShelfFilter.allCases) { filter in
          Button {
            store.filter = filter
          } label: {
            Text(filter.label)
              .font(.subheadline.weight(.medium))
              .padding(.horizontal, 12)
              .frame(height: 34)
          }
          .buttonStyle(.bordered)
          .tint(store.filter == filter ? .accentColor : .secondary)
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .background(.bar)
  }

  private var shelfList: some View {
    List {
      ForEach(store.visibleItems()) { item in
        ShelfItemRow(
          item: item,
          isSelected: store.selectedIDs.contains(item.id),
          isEditing: editMode.isEditing
        )
        .contentShape(Rectangle())
        .onTapGesture {
          if editMode.isEditing {
            store.toggleSelection(for: item)
          } else {
            selectedDetail = ShelfDetailSelection(id: item.id)
          }
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            store.delete(item)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
        .swipeActions(edge: .leading) {
          if item.isStack {
            Button {
              store.splitStack(item)
            } label: {
              Label("Split", systemImage: "square.stack.3d.up.slash")
            }
            .tint(.indigo)
          }
        }
      }
    }
    .listStyle(.plain)
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

private struct EmptyShelfView: View {
  let importAction: () -> Void
  let pasteAction: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Shelf Empty", systemImage: "tray")
    } description: {
      Text("Import files, paste clipboard content, or drop items here.")
    } actions: {
      HStack {
        Button("Import Files", action: importAction)
          .buttonStyle(.borderedProminent)
        Button("Paste", action: pasteAction)
          .buttonStyle(.bordered)
      }
    }
  }
}

private struct DropOverlay: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 18)
      .strokeBorder(.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
      .background(.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        Label("Drop to hold", systemImage: "tray.and.arrow.down.fill")
          .font(.title3.weight(.semibold))
          .padding(18)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
      .padding(18)
      .allowsHitTesting(false)
  }
}

private struct ShelfDetailSelection: Identifiable {
  let id: ShelfItem.ID
}

private extension EditMode {
  var isEditing: Bool { self == .active }
}

#Preview {
  ContentView(store: ShelfStore.preview)
}
