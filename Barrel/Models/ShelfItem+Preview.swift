import Foundation

extension ShelfItem {
  static let sampleFile = ShelfItem(
    title: "Project Brief",
    kind: .file,
    fileName: "Project Brief.pdf",
    relativePath: nil
  )

  static let sampleText = ShelfItem(
    title: "Meeting follow-up",
    kind: .text,
    text: "Send updated assets after the design review."
  )

  static let sampleStack = ShelfItem(
    id: UUID(uuidString: "60D1B05E-40A3-433D-9B25-587EB5E35C51")!,
    title: "Launch assets",
    kind: .stack,
    children: [.sampleFile, .sampleText]
  )
}

extension ShelfStore {
  @MainActor
  static var preview: ShelfStore {
    let store = ShelfStore(importer: ImportService())
    store.items = [.sampleStack, .sampleFile, .sampleText]
    return store
  }
}
