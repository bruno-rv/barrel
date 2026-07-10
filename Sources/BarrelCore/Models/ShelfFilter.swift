import Foundation

public enum ShelfFilter: String, CaseIterable, Codable, Identifiable, Sendable {
  case all
  case files
  case images
  case links
  case text
  case stacks
  case trash

  public var id: String { rawValue }

  public var label: String {
    return switch self {
    case .all: "All"
    case .files: "Files"
    case .images: "Images"
    case .links: "Links"
    case .text: "Text"
    case .stacks: "Stacks"
    case .trash: "Trash"
    }
  }

  public var systemImage: String {
    switch self {
    case .all: "tray.full"
    case .files: "doc"
    case .images: "photo"
    case .links: "link"
    case .text: "text.alignleft"
    case .stacks: "square.stack.3d.up"
    case .trash: "trash"
    }
  }

  public func accepts(_ item: ShelfItem) -> Bool {
    if self == .trash {
      return item.trashedAt != nil
    }
    guard item.trashedAt == nil else {
      return false
    }

    return switch self {
    case .all: true
    case .files: item.kind == .file
    case .images: item.kind == .image
    case .links: item.kind == .link
    case .text: item.kind == .text
    case .stacks: item.kind == .stack
    case .trash: false
    }
  }

  public func filter(_ items: [ShelfItem], query: String) -> [ShelfItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { item in
      accepts(item) && (query.isEmpty || item.matches(query))
    }
  }
}
