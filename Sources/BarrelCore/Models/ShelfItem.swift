import Foundation

public enum ShelfKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case file
  case image
  case link
  case text
  case stack

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .file: "File"
    case .image: "Image"
    case .link: "Link"
    case .text: "Text"
    case .stack: "Stack"
    }
  }

  public var systemImage: String {
    switch self {
    case .file: "doc"
    case .image: "photo"
    case .link: "link"
    case .text: "text.alignleft"
    case .stack: "square.stack.3d.up"
    }
  }
}

public enum ShelfOrigin: String, Codable, Sendable {
  case imported
  case clipboard
  case shortcut
  case sync
}

public struct ShelfItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var title: String
  public var kind: ShelfKind
  public var createdAt: Date
  public var updatedAt: Date
  public var fileName: String?
  public var relativePath: String?
  public var text: String?
  public var children: [ShelfItem]
  public var origin: ShelfOrigin
  public var expiresAt: Date?
  public var isPinned: Bool
  public var contentHash: String?
  public var trashedAt: Date?
  public var revision: Int
  public var modifiedByDeviceID: String

  public init(
    id: UUID = UUID(),
    title: String,
    kind: ShelfKind,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    fileName: String? = nil,
    relativePath: String? = nil,
    text: String? = nil,
    children: [ShelfItem] = [],
    origin: ShelfOrigin = .imported,
    expiresAt: Date? = nil,
    isPinned: Bool = false,
    contentHash: String? = nil,
    trashedAt: Date? = nil,
    revision: Int = 0,
    modifiedByDeviceID: String = ""
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
    self.origin = origin
    self.expiresAt = expiresAt
    self.isPinned = isPinned
    self.contentHash = contentHash
    self.trashedAt = trashedAt
    self.revision = revision
    self.modifiedByDeviceID = modifiedByDeviceID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    kind = try container.decode(ShelfKind.self, forKey: .kind)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    children = try container.decodeIfPresent([ShelfItem].self, forKey: .children) ?? []
    origin = try container.decodeIfPresent(ShelfOrigin.self, forKey: .origin) ?? .imported
    expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
    trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
    revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    modifiedByDeviceID = try container.decodeIfPresent(String.self, forKey: .modifiedByDeviceID) ?? ""
  }

  public var isStack: Bool { kind == .stack }

  public var detail: String {
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

  public var isExpired: Bool {
    isExpired(at: Date())
  }

  public func isExpired(at date: Date) -> Bool {
    !isPinned && expiresAt.map { $0 <= date } == true
  }

  public func matches(_ query: String) -> Bool {
    let haystacks = [title, detail, text ?? ""]
    if haystacks.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
      return true
    }
    return children.contains { $0.matches(query) }
  }
}
