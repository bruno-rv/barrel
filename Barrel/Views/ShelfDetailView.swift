import SwiftUI
import UIKit

struct ShelfDetailView: View {
  @ObservedObject var store: ShelfStore
  let itemID: ShelfItem.ID

  @Environment(\.dismiss) private var dismiss
  @State private var renameText = ""
  @State private var previewDocument: PreviewDocument?

  private var item: ShelfItem? {
    store.item(with: itemID)
  }

  var body: some View {
    NavigationStack {
      Group {
        if let item {
          List {
            headerSection(item)
            previewSection(item)

            if item.isStack {
              stackSection(item)
            }

            metadataSection(item)
          }
          .listStyle(.insetGrouped)
          .navigationTitle("Item")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              Button("Done") {
                dismiss()
              }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
              shareView(for: item)

              Button(role: .destructive) {
                store.delete(item)
                dismiss()
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
          .onAppear {
            renameText = item.title
          }
        } else {
          ContentUnavailableView("Item Missing", systemImage: "questionmark.folder")
        }
      }
      .sheet(item: $previewDocument) { document in
        QuickLookPreview(url: document.url)
      }
    }
  }

  private func headerSection(_ item: ShelfItem) -> some View {
    Section {
      HStack(spacing: 14) {
        Image(systemName: item.kind.systemImage)
          .font(.title2.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 52, height: 52)
          .background(.accentColor, in: RoundedRectangle(cornerRadius: 8))

        VStack(alignment: .leading, spacing: 8) {
          TextField("Title", text: $renameText)
            .font(.headline)
            .textInputAutocapitalization(.sentences)
            .onSubmit {
              store.rename(item, title: renameText)
            }

          Text(item.countLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)

      Button("Rename") {
        store.rename(item, title: renameText)
      }
      .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  @ViewBuilder
  private func previewSection(_ item: ShelfItem) -> some View {
    if item.kind == .text, let text = item.text {
      Section("Text") {
        Text(text)
          .textSelection(.enabled)
          .font(.body.monospaced(false))
          .padding(.vertical, 4)
      }
    } else if item.kind == .link, let text = item.text, let url = URL(string: text) {
      Section("Link") {
        Link(destination: url) {
          Label(text, systemImage: "safari")
            .lineLimit(3)
        }
      }
    } else if item.kind == .image, let url = store.fileURL(for: item), let image = UIImage(contentsOfFile: url.path) {
      Section("Preview") {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 320)
          .frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 8))

        Button {
          previewDocument = PreviewDocument(url: url)
        } label: {
          Label("Open in Quick Look", systemImage: "eye")
        }
      }
    } else if let url = store.fileURL(for: item) {
      Section("File") {
        LabeledContent("Name", value: url.lastPathComponent)
        Button {
          previewDocument = PreviewDocument(url: url)
        } label: {
          Label("Open in Quick Look", systemImage: "eye")
        }
      }
    }
  }

  private func stackSection(_ item: ShelfItem) -> some View {
    Section("Stack") {
      ForEach(item.children) { child in
        HStack(spacing: 12) {
          Image(systemName: child.kind.systemImage)
            .foregroundStyle(.accentColor)
            .frame(width: 24)

          VStack(alignment: .leading) {
            Text(child.title)
              .font(.body)
            Text(child.subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      }

      Button {
        store.splitStack(item)
        dismiss()
      } label: {
        Label("Split Stack", systemImage: "square.stack.3d.up.slash")
      }
    }
  }

  private func metadataSection(_ item: ShelfItem) -> some View {
    Section("Metadata") {
      LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
      LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
      LabeledContent("Type", value: item.kind.label)
    }
  }

  @ViewBuilder
  private func shareView(for item: ShelfItem) -> some View {
    if let url = store.fileURL(for: item) {
      ShareLink(item: url) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
    } else if let text = item.text {
      ShareLink(item: text) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
    }
  }
}

struct PreviewDocument: Identifiable {
  let id = UUID()
  let url: URL
}

#Preview {
  ShelfDetailView(store: ShelfStore.preview, itemID: ShelfItem.sampleStack.id)
}
