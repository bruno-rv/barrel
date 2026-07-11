import AppKit
import Foundation
import ImageIO
import SwiftUI

actor ThumbnailCache {
  static let shared = ThumbnailCache()

  private let cache = NSCache<NSString, NSImage>()

  func image(for url: URL, itemID: UUID, maxPixelSize: CGFloat) async -> NSImage? {
    let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? .distantPast
    let key = NSString(
      string: "\(itemID.uuidString)|\(url.standardizedFileURL.path)|\(modificationDate.timeIntervalSince1970)|\(Int(maxPixelSize))"
    )
    if let cached = cache.object(forKey: key) {
      return cached
    }

    let image = await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil as NSImage?
      }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true
      ]
      guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
      }
      return NSImage(cgImage: cgImage, size: .zero)
    }.value
    if let image {
      cache.setObject(image, forKey: key)
    }
    return image
  }
}

struct CachedThumbnailView: View {
  let url: URL
  let itemID: UUID
  let maxPixelSize: CGFloat
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
      } else {
        Color.secondary.opacity(0.12)
          .overlay {
            Image(systemName: "photo")
              .foregroundStyle(.secondary)
          }
      }
    }
    .task(id: taskID) {
      image = nil
      image = await ThumbnailCache.shared.image(
        for: url,
        itemID: itemID,
        maxPixelSize: maxPixelSize
      )
    }
  }

  private var taskID: String {
    "\(itemID.uuidString)|\(url.path)|\(Int(maxPixelSize))"
  }
}
