import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

final class ImportService {
  private let fileManager: FileManager
  private let supportDirectory: URL
  private let itemsDirectory: URL
  let manifestURL: URL

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    supportDirectory = base.appendingPathComponent("Barrel", isDirectory: true)
    itemsDirectory = supportDirectory.appendingPathComponent("Items", isDirectory: true)
    manifestURL = supportDirectory.appendingPathComponent("shelf.json")
  }

  func prepareStorage() throws {
    try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
  }

  func loadManifest() throws -> [ShelfItem] {
    try prepareStorage()
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      return []
    }
    let data = try Data(contentsOf: manifestURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([ShelfItem].self, from: data)
  }

  func saveManifest(_ items: [ShelfItem]) throws {
    try prepareStorage()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(items)
    try data.write(to: manifestURL, options: [.atomic])
  }

  func resolvedURL(for item: ShelfItem) -> URL? {
    guard let relativePath = item.relativePath else {
      return nil
    }
    return supportDirectory.appendingPathComponent(relativePath)
  }

  func makeFileItem(from url: URL) throws -> ShelfItem {
    try prepareStorage()
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let id = UUID()
    let originalName = url.lastPathComponent.isEmpty ? "Imported File" : url.lastPathComponent
    let itemDirectory = itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
    let destination = itemDirectory.appendingPathComponent(originalName)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: url, to: destination)

    let type = UTType(filenameExtension: destination.pathExtension)
    let kind: ShelfKind = type?.conforms(to: .image) == true ? .image : .file
    let title = destination.deletingPathExtension().lastPathComponent
    let relativePath = "Items/\(id.uuidString)/\(originalName)"

    return ShelfItem(
      id: id,
      title: title,
      kind: kind,
      fileName: originalName,
      relativePath: relativePath
    )
  }

  func makeTextItem(_ text: String) -> ShelfItem {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = trimmed
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { String($0.prefix(48)) } ?? "Text"
    return ShelfItem(title: title.isEmpty ? "Text" : title, kind: .text, text: text)
  }

  func makeLinkItem(_ url: URL) -> ShelfItem {
    let title = url.host(percentEncoded: false) ?? url.absoluteString
    return ShelfItem(title: title, kind: .link, text: url.absoluteString)
  }

  func makeImageItem(_ image: UIImage) throws -> ShelfItem {
    try prepareStorage()
    guard let data = image.pngData() else {
      throw ImportError.couldNotEncodeImage
    }

    let id = UUID()
    let fileName = "Image-\(id.uuidString.prefix(8)).png"
    let itemDirectory = itemsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
    let destination = itemDirectory.appendingPathComponent(fileName)
    try data.write(to: destination, options: [.atomic])

    return ShelfItem(
      id: id,
      title: "Image",
      kind: .image,
      fileName: fileName,
      relativePath: "Items/\(id.uuidString)/\(fileName)"
    )
  }

  func deleteFiles(for item: ShelfItem) {
    if let url = resolvedURL(for: item) {
      let itemDirectory = url.deletingLastPathComponent()
      try? fileManager.removeItem(at: itemDirectory)
    }
    item.children.forEach(deleteFiles)
  }

  func importItems(from providers: [NSItemProvider]) async throws -> [ShelfItem] {
    var imported: [ShelfItem] = []

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
         let url = try await provider.loadURL(typeIdentifier: UTType.fileURL.identifier) {
        imported.append(try makeFileItem(from: url))
      } else if provider.canLoadObject(ofClass: UIImage.self) {
        let image = try await provider.loadObject(UIImage.self)
        imported.append(try makeImageItem(image))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                let url = try await provider.loadURL(typeIdentifier: UTType.url.identifier) {
        imported.append(makeLinkItem(url))
      } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                let text = try await provider.loadString(typeIdentifier: UTType.text.identifier) {
        if let url = URL(string: text), url.scheme != nil {
          imported.append(makeLinkItem(url))
        } else {
          imported.append(makeTextItem(text))
        }
      }
    }

    return imported
  }

  enum ImportError: LocalizedError {
    case couldNotEncodeImage

    var errorDescription: String? {
      switch self {
      case .couldNotEncodeImage: "The pasted image could not be saved."
      }
    }
  }
}

private extension NSItemProvider {
  func loadURL(typeIdentifier: String) async throws -> URL? {
    let item = try await loadItemValue(typeIdentifier: typeIdentifier)
    if let url = item as? URL {
      return url
    }
    if let data = item as? Data {
      return URL(dataRepresentation: data, relativeTo: nil)
    }
    if let string = item as? String {
      return URL(string: string)
    }
    return nil
  }

  func loadString(typeIdentifier: String) async throws -> String? {
    let item = try await loadItemValue(typeIdentifier: typeIdentifier)
    if let string = item as? String {
      return string
    }
    if let data = item as? Data {
      return String(data: data, encoding: .utf8)
    }
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
