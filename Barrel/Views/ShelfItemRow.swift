import SwiftUI

struct ShelfItemRow: View {
  let item: ShelfItem
  let isSelected: Bool
  let isEditing: Bool

  var body: some View {
    HStack(spacing: 14) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 8)
          .fill(iconBackground)
          .frame(width: 48, height: 48)
        Image(systemName: item.kind.systemImage)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)

        if item.isStack {
          Text("\(item.children.count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(.black.opacity(0.35), in: Capsule())
            .offset(x: 5, y: 5)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.headline)
          .lineLimit(1)

        Text(item.subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 8) {
        Text(item.createdAt, style: .date)
          .font(.caption)
          .foregroundStyle(.secondary)

        if isEditing {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? .accentColor : .secondary)
        } else {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 6)
  }

  private var iconBackground: Color {
    switch item.kind {
    case .file: Color.blue
    case .image: Color.teal
    case .link: Color.orange
    case .text: Color.purple
    case .stack: Color.indigo
    }
  }
}

#Preview {
  List {
    ShelfItemRow(item: .sampleFile, isSelected: false, isEditing: false)
    ShelfItemRow(item: .sampleStack, isSelected: true, isEditing: true)
  }
}
