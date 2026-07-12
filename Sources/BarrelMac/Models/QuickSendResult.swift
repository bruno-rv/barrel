import Foundation

enum QuickSendAvailableAction: Hashable, Sendable {
  case open
  case reveal
}

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
  let shelfItemID: UUID?
  let historyEventID: UUID?
  let destinationID: RecentDestination.ID?
  let recency: Date
  let isPrimaryEnabled: Bool
  let availableActions: Set<QuickSendAvailableAction>

  var isSecondaryEnabled: Bool { !availableActions.isEmpty }

  init(
    semanticID: String,
    group: QuickSendResultGroup,
    title: String,
    subtitle: String? = nil,
    searchTerms: [String] = [],
    finderURLs: [URL] = [],
    shelfItemID: UUID? = nil,
    historyEventID: UUID? = nil,
    destinationID: RecentDestination.ID? = nil,
    recency: Date = .distantPast,
    isPrimaryEnabled: Bool,
    availableActions: Set<QuickSendAvailableAction> = [],
    isSecondaryEnabled: Bool = false
  ) {
    id = semanticID
    self.semanticID = semanticID
    self.group = group
    self.title = title
    self.subtitle = subtitle
    self.searchTerms = searchTerms
    self.finderURLs = finderURLs
    self.shelfItemID = shelfItemID
    self.historyEventID = historyEventID
    self.destinationID = destinationID
    self.recency = recency
    self.isPrimaryEnabled = isPrimaryEnabled
    self.availableActions = availableActions.isEmpty && isSecondaryEnabled
      ? [.open, .reveal]
      : availableActions
  }
}
