import AppKit
import BarrelCore
import Foundation
import UniformTypeIdentifiers

struct ProviderImportResult {
  var items: [ShelfItem] = []
  var errors: [String] = []
}

@MainActor
final class ImportService {
  func importItems(
    from providers: [NSItemProvider],
    into repository: ShelfRepository,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) async -> ProviderImportResult {
    var result = ProviderImportResult()
    for provider in providers {
      do {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try await provider.loadURL(typeIdentifier: UTType.fileURL.identifier) {
          append(
            await repository.importFiles([url], origin: origin, expiresAt: expiresAt),
            to: &result
          )
        } else if provider.canLoadObject(ofClass: NSImage.self) {
          let image = try await provider.loadObject(NSImage.self)
          append(
            try await importImage(image, into: repository, origin: origin, expiresAt: expiresAt),
            to: &result
          )
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  let url = try await provider.loadURL(typeIdentifier: UTType.url.identifier) {
          result.items.append(
            try await repository.addText(
              url.absoluteString,
              kind: .link,
              origin: origin,
              expiresAt: expiresAt
            )
          )
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                  let text = try await provider.loadString(typeIdentifier: UTType.text.identifier) {
          let kind: ShelfKind = URL(string: text)?.scheme == nil ? .text : .link
          result.items.append(
            try await repository.addText(text, kind: kind, origin: origin, expiresAt: expiresAt)
          )
        }
      } catch {
        result.errors.append(error.localizedDescription)
      }
    }
    return result
  }

  func importPasteboard(
    _ pasteboard: NSPasteboard,
    into repository: ShelfRepository,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) async -> ProviderImportResult {
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
      var result = ProviderImportResult()
      append(await repository.importFiles(urls, origin: origin, expiresAt: expiresAt), to: &result)
      return result
    }
    if let image = NSImage(pasteboard: pasteboard) {
      do {
        var result = ProviderImportResult()
        append(
          try await importImage(image, into: repository, origin: origin, expiresAt: expiresAt),
          to: &result
        )
        return result
      } catch {
        return ProviderImportResult(errors: [error.localizedDescription])
      }
    }
    if let string = pasteboard.string(forType: .URL), let url = URL(string: string) {
      return await importText(url.absoluteString, kind: .link, into: repository, origin: origin, expiresAt: expiresAt)
    }
    if let string = pasteboard.string(forType: .string), !string.isEmpty {
      let kind: ShelfKind = URL(string: string)?.scheme == nil ? .text : .link
      return await importText(string, kind: kind, into: repository, origin: origin, expiresAt: expiresAt)
    }
    return ProviderImportResult()
  }

  private func importText(
    _ text: String,
    kind: ShelfKind,
    into repository: ShelfRepository,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) async -> ProviderImportResult {
    do {
      let item = try await repository.addText(text, kind: kind, origin: origin, expiresAt: expiresAt)
      return ProviderImportResult(items: [item])
    } catch {
      return ProviderImportResult(errors: [error.localizedDescription])
    }
  }

  private func importImage(
    _ image: NSImage,
    into repository: ShelfRepository,
    origin: ShelfOrigin,
    expiresAt: Date?
  ) async throws -> ImportOutcome {
    guard let data = image.pngData else {
      throw ImportError.couldNotEncodeImage
    }
    let temporaryURL = try await Task.detached(priority: .utility) {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BarrelImport-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("Image.png")
      try data.write(to: url, options: .atomic)
      return url
    }.value
    defer { try? FileManager.default.removeItem(at: temporaryURL.deletingLastPathComponent()) }
    return await repository.importFiles([temporaryURL], origin: origin, expiresAt: expiresAt)
  }

  private func append(_ outcome: ImportOutcome, to result: inout ProviderImportResult) {
    result.items.append(contentsOf: outcome.successes)
    result.errors.append(contentsOf: outcome.failures.map(\.message))
  }

  enum ImportError: LocalizedError {
    case couldNotEncodeImage

    var errorDescription: String? {
      "The pasted image could not be saved."
    }
  }
}

private extension NSImage {
  var pngData: Data? {
    guard let tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}

private extension NSItemProvider {
  func loadURL(typeIdentifier: String) async throws -> URL? {
    let item = try await loadItemValue(typeIdentifier: typeIdentifier)
    if let url = item as? URL { return url }
    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
    if let string = item as? String { return URL(string: string) }
    return nil
  }

  func loadString(typeIdentifier: String) async throws -> String? {
    let item = try await loadItemValue(typeIdentifier: typeIdentifier)
    if let string = item as? String { return string }
    if let data = item as? Data { return String(data: data, encoding: .utf8) }
    return nil
  }

  func loadItemValue(typeIdentifier: String) async throws -> NSSecureCoding? {
    try await withCheckedThrowingContinuation { continuation in
      loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: item)
        }
      }
    }
  }

  func loadObject<T: NSItemProviderReading>(_ type: T.Type) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadObject(ofClass: type) { object, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let object = object as? T {
          continuation.resume(returning: object)
        } else {
          continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
        }
      }
    }
  }
}
