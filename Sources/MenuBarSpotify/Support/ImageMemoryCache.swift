import AppKit
import Foundation

@MainActor
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var tasks: [URL: Task<NSImage, Error>] = [:]

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    func image(for url: URL) async throws -> NSImage {
        let cacheKey = url as NSURL
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        if let task = tasks[url] {
            return try await task.value
        }

        let task = Task<NSImage, Error> {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else {
                throw ImageCacheError.invalidImage
            }
            return image
        }

        tasks[url] = task
        do {
            let image = try await task.value
            cache.setObject(image, forKey: cacheKey, cost: dataCost(for: image))
            tasks[url] = nil
            return image
        } catch {
            tasks[url] = nil
            throw error
        }
    }

    private func dataCost(for image: NSImage) -> Int {
        image.tiffRepresentation?.count ?? 0
    }
}

private enum ImageCacheError: Error {
    case invalidImage
}
