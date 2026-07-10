import Foundation
import UniformTypeIdentifiers

enum ShelfKind: String, CaseIterable, Codable, Identifiable {
  case file
  case image
  case link
  case text
  case stack

  var id: String { rawValue }

  var label: String {
    switch self {
    case .file: "Files"
    case .image: "Images"
    case .link: "Links"
    case .text: "Text"
    case .stack: "Stacks"
    }
  }

  var systemImage: String {
    switch self {
    case .file: "doc"
    case .image: "photo"
    case .link: "link"
    case .text: "text.alignleft"
    case .stack: "square.stack.3d.up"
    }
  }
}

enum ShelfFilter: String, CaseIterable, Identifiable {
  case all
  case files
  case images
  case links
  case text
  case stacks

  var id: String { rawValue }

  var label: String {
    switch self {
    case .all: "All"
    case .files: "Files"
    case .images: "Images"
    case .links: "Links"
    case .text: "Text"
    case .stacks: "Stacks"
    }
  }

  func accepts(_ item: ShelfItem) -> Bool {
    switch self {
    case .all: true
    case .files: item.kind == .file
    case .images: item.kind == .image
    case .links: item.kind == .link
    case .text: item.kind == .text
    case .stacks: item.kind == .stack
    }
  }
}

struct ShelfItem: Identifiable, Codable, Hashable {
  var id: UUID
  var title: String
  var kind: ShelfKind
  var createdAt: Date
  var updatedAt: Date
  var fileName: String?
  var relativePath: String?
  var text: String?
  var children: [ShelfItem]

  init(
    id: UUID = UUID(),
    title: String,
    kind: ShelfKind,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    fileName: String? = nil,
    relativePath: String? = nil,
    text: String? = nil,
    children: [ShelfItem] = []
  ) {
    self.id = id
    self.title = title
    self.kind = kind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.fileName = fileName
    self.relativePath = relativePath
    self.text = text
    self.children = children
  }

  var isStack: Bool { kind == .stack }
  var countLabel: String { isStack ? "\(children.count) items" : kind.label.dropLast().description }

  var subtitle: String {
    if isStack {
      return "\(children.count) held items"
    }
    if let fileName {
      return fileName
    }
    if let text, !text.isEmpty {
      return text
    }
    return kind.label
  }
}
