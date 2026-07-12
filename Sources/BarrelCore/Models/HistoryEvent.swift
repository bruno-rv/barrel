import Foundation

public enum HistoryEventKind: String, Codable, Sendable {
  case export
  case undo
}

public struct HistoryEvent: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var itemID: UUID
  public var kind: HistoryEventKind
  public var sourceName: String
  public var destinationName: String
  public var destinationURL: URL?
  public var destinationBookmark: Data?
  public var fileName: String
  public var contentHash: String
  public var timestamp: Date
  public var reversedEventID: UUID?
  public var reversedByEventID: UUID?

  public init(
    id: UUID = UUID(),
    itemID: UUID,
    kind: HistoryEventKind,
    sourceName: String,
    destinationName: String,
    destinationURL: URL?,
    destinationBookmark: Data?,
    fileName: String,
    contentHash: String,
    timestamp: Date,
    reversedEventID: UUID?,
    reversedByEventID: UUID?
  ) {
    self.id = id
    self.itemID = itemID
    self.kind = kind
    self.sourceName = sourceName
    self.destinationName = destinationName
    self.destinationURL = destinationURL
    self.destinationBookmark = destinationBookmark
    self.fileName = fileName
    self.contentHash = contentHash
    self.timestamp = timestamp
    self.reversedEventID = reversedEventID
    self.reversedByEventID = reversedByEventID
  }
}
