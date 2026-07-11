import AppIntents
import BarrelCore
import Foundation
import UniformTypeIdentifiers

struct HoldFilesIntent: AppIntent {
  static let title: LocalizedStringResource = "Hold Files in Barrel"

  @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
  var files: [IntentFile]

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BarrelIntent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    var urls: [URL] = []
    for file in files {
      if let fileURL = file.fileURL {
        urls.append(fileURL)
      } else {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent(file.filename)
        try file.data.write(to: url)
        urls.append(url)
      }
    }
    let outcome = await BarrelEnvironment.shared.repository.importFiles(
      urls,
      origin: .shortcut,
      expiresAt: nil
    )
    guard !outcome.successes.isEmpty else {
      throw BarrelIntentError.importFailed(outcome.failures.first?.message ?? "No files were supplied.")
    }
    NotificationCenter.default.post(name: .repositoryDidChange, object: nil)
    return .result(dialog: "Held \(outcome.successes.count) file(s) in Barrel.")
  }
}

struct HoldTextIntent: AppIntent {
  static let title: LocalizedStringResource = "Hold Text in Barrel"

  @Parameter(title: "Text")
  var text: String

  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await BarrelEnvironment.shared.repository.addText(
      text,
      kind: .text,
      origin: .shortcut,
      expiresAt: nil
    )
    NotificationCenter.default.post(name: .repositoryDidChange, object: nil)
    return .result(dialog: "Held the text in Barrel.")
  }
}

struct HoldLinkIntent: AppIntent {
  static let title: LocalizedStringResource = "Hold a Link in Barrel"

  @Parameter(title: "Link")
  var link: URL

  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await BarrelEnvironment.shared.repository.addText(
      link.absoluteString,
      kind: .link,
      origin: .shortcut,
      expiresAt: nil
    )
    NotificationCenter.default.post(name: .repositoryDidChange, object: nil)
    return .result(dialog: "Held the link in Barrel.")
  }
}

struct ShowShelfIntent: AppIntent {
  static let title: LocalizedStringResource = "Show Barrel Shelf"
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    await MainActor.run {
      NotificationCenter.default.post(name: .showBarrelShelf, object: nil)
    }
    return .result(dialog: "Opened the Barrel shelf.")
  }
}

struct ClearExpiredIntent: AppIntent {
  static let title: LocalizedStringResource = "Clear Expired Barrel Items"

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = try await BarrelEnvironment.shared.repository.cleanup()
    NotificationCenter.default.post(name: .repositoryDidChange, object: nil)
    if outcome.requiresManualCleanup {
      return .result(dialog: "Expired items were cleared. Manual cleanup is still required to meet the storage quota.")
    }
    return .result(dialog: "Expired items were cleared.")
  }
}

private enum BarrelIntentError: LocalizedError {
  case importFailed(String)

  var errorDescription: String? {
    switch self {
    case .importFailed(let message): message
    }
  }
}
