import BarrelCore

extension ShelfItem {
  static let samplePDF = ShelfItem(title: "Project Brief", kind: .file, fileName: "Project Brief.pdf")
  static let sampleText = ShelfItem(title: "Follow-up", kind: .text, text: "Send the revised export before 4 PM.")
  static let sampleLink = ShelfItem(title: "setapp.com", kind: .link, text: "https://setapp.com/apps/yoink")
  static let sampleStack = ShelfItem(title: "Launch Assets", kind: .stack, children: [.samplePDF, .sampleText, .sampleLink])
}
