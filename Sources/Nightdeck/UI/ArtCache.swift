import AppKit
import Foundation
import ImageIO

/// Bounded in-memory cover cache. Images are downscaled and never written to disk.
@MainActor
final class ArtCache {
    static let shared = ArtCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 24_000_000
        return cache
    }()
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func image(for path: String, loader: @MainActor @escaping (String) async -> Data?) async -> NSImage? {
        let key = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let existing = inflight[key] { return await existing.value }
        let task = Task<NSImage?, Never> { @MainActor in
            guard let data = await loader(key) else { return nil }
            let cg = await Task.detached(priority: .utility) { thumbnail(data) }.value
            guard let cg else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
        }
        return image
    }
}

private nonisolated func thumbnail(_ data: Data) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 480,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}
