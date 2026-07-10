import AppKit
import SwiftUI

struct DetailView: View {
  @ObservedObject var store: ShelfStore
  let item: ShelfItem?
  @State private var renameText = ""

  var body: some View {
    Group {
      if let item {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header(item)
            preview(item)
            actions(item)
            if item.isStack {
              stackContents(item)
            }
            metadata(item)
          }
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
          renameText = item.title
        }
        .onChange(of: item.id) {
          renameText = item.title
        }
      } else {
        ContentUnavailableView(
          "No Item Selected",
          systemImage: "tray",
          description: Text("Select an item from the shelf or drop something into the window.")
        )
      }
    }
  }

  private func header(_ item: ShelfItem) -> some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: item.kind.systemImage)
        .font(.title.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 58, height: 58)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 8) {
        TextField("Title", text: $renameText)
          .textFieldStyle(.plain)
          .font(.title2.weight(.semibold))
          .onSubmit {
            store.rename(item, title: renameText)
          }

        Text(item.detail)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  @ViewBuilder
  private func preview(_ item: ShelfItem) -> some View {
    if item.kind == .text, let text = item.text {
      SectionBox(title: "Text") {
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if item.kind == .link, let text = item.text {
      SectionBox(title: "Link") {
        Text(text)
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      }
    } else if item.kind == .image, let url = store.fileURL(for: item), let image = NSImage(contentsOf: url) {
      SectionBox(title: "Preview") {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 340)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    } else if let url = store.fileURL(for: item) {
      SectionBox(title: "File") {
        HStack {
          Image(systemName: "doc")
            .font(.title2)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading) {
            Text(url.lastPathComponent)
              .font(.headline)
            Text(url.path)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
      }
    }
  }

  private func actions(_ item: ShelfItem) -> some View {
    HStack {
      Button {
        store.rename(item, title: renameText)
      } label: {
        Label("Rename", systemImage: "pencil")
      }

      Button {
        store.open(item)
      } label: {
        Label(item.kind == .link ? "Open Link" : "Open", systemImage: "arrow.up.right.square")
      }

      if store.fileURL(for: item) != nil {
        Button {
          store.reveal(item)
        } label: {
          Label("Reveal", systemImage: "finder")
        }
      }

      if item.isStack {
        Button {
          store.splitStack(item)
        } label: {
          Label("Split", systemImage: "square.stack.3d.up.slash")
        }
      }

      Spacer()

      Button(role: .destructive) {
        store.delete(item)
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
  }

  private func stackContents(_ item: ShelfItem) -> some View {
    SectionBox(title: "Stack Contents") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(item.children) { child in
          HStack {
            Image(systemName: child.kind.systemImage)
              .foregroundStyle(Color.accentColor)
              .frame(width: 20)
            VStack(alignment: .leading) {
              Text(child.title)
              Text(child.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }

  private func metadata(_ item: ShelfItem) -> some View {
    SectionBox(title: "Metadata") {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
        GridRow {
          Text("Added").foregroundStyle(.secondary)
          Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        GridRow {
          Text("Updated").foregroundStyle(.secondary)
          Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        GridRow {
          Text("Type").foregroundStyle(.secondary)
          Text(item.kind.label)
        }
      }
    }
  }
}

private struct SectionBox<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }
}

#Preview {
  DetailView(store: .preview, item: .sampleStack)
    .frame(width: 620, height: 540)
}
