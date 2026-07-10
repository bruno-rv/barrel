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
    case .file: "File"
    case .image: "Image"
    case .link: "Link"
    case .text: "Text"
    case .stack: "Stack"
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

  var systemImage: String {
    switch self {
    case .all: "tray.full"
    case .files: "doc"
    case .images: "photo"
    case .links: "link"
    case .text: "text.alignleft"
    case .stacks: "square.stack.3d.up"
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

  var detail: String {
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

  func matches(_ query: String) -> Bool {
    let haystacks = [title, detail, text ?? ""]
    if haystacks.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
      return true
    }
    return children.contains { $0.matches(query) }
  }
}

extension ShelfItem {
  static let samplePDF = ShelfItem(title: "Project Brief", kind: .file, fileName: "Project Brief.pdf")
  static let sampleText = ShelfItem(title: "Follow-up", kind: .text, text: "Send the revised export before 4 PM.")
  static let sampleLink = ShelfItem(title: "setapp.com", kind: .link, text: "https://setapp.com/apps/yoink")
  static let sampleStack = ShelfItem(title: "Launch Assets", kind: .stack, children: [.samplePDF, .sampleText, .sampleLink])
}
