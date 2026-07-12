import Foundation

enum QuickSendResultGroup: Int, CaseIterable, Sendable {
  case finderSelection
  case undoLatest
  case temporary
  case history
  case destination
}

struct QuickSendResult: Identifiable, Equatable, Sendable {
  typealias ID = String

  let id: ID
  let semanticID: String
  let group: QuickSendResultGroup
  let title: String
  let subtitle: String?
  let searchTerms: [String]
  let finderURLs: [URL]
  let recency: Date
  let isPrimaryEnabled: Bool

  init(
    semanticID: String,
    group: QuickSendResultGroup,
    title: String,
    subtitle: String? = nil,
    searchTerms: [String] = [],
    finderURLs: [URL] = [],
    recency: Date = .distantPast,
    isPrimaryEnabled: Bool
  ) {
    id = semanticID
    self.semanticID = semanticID
    self.group = group
    self.title = title
    self.subtitle = subtitle
    self.searchTerms = searchTerms
    self.finderURLs = finderURLs
    self.recency = recency
    self.isPrimaryEnabled = isPrimaryEnabled
  }
}
