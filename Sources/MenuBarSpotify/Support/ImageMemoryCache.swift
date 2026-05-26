import AppKit
import Foundation

@MainActor
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private var images: [URL: NSImage] = [:]
    private var tasks: [URL: Task<NSImage, Error>] = [:]

    func image(for url: URL) async throws -> NSImage {
        if let cached = images[url] {
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
            images[url] = image
            tasks[url] = nil
            return image
        } catch {
            tasks[url] = nil
            throw error
        }
    }
}

private enum ImageCacheError: Error {
    case invalidImage
}
