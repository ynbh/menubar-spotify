import Foundation
import AppKit

enum AppLog {
    private static let queue = DispatchQueue(label: "com.yashasbhat.MenuBarSpotify.file-log")
    private static let maxBytes: UInt64 = 1_000_000

    static var fileURL: URL {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MenuBarSpotify", isDirectory: true)
        return directory.appendingPathComponent("MenuBarSpotify.log")
    }

    static func event(_ message: String, metadata: [String: CustomStringConvertible?] = [:]) {
        write(level: "INFO", message: message, metadata: metadata)
    }

    static func error(_ message: String, _ error: Error? = nil, metadata: [String: CustomStringConvertible?] = [:]) {
        var fields = metadata
        if let error {
            fields["error"] = error.localizedDescription
            fields["type"] = String(describing: Swift.type(of: error))
        }
        write(level: "ERROR", message: message, metadata: fields)
    }

    static func pathDescription() -> String {
        fileURL.path
    }

    static func revealInFinder() {
        queue.async {
            let url = fileURL
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try "".write(to: url, atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                NSLog("MenuBarSpotify log reveal failed: %@", error.localizedDescription)
            }
        }
    }

    private static func write(level: String, message: String, metadata: [String: CustomStringConvertible?]) {
        let timestamp = ISO8601DateFormatter.menuBarSpotify.string(from: Date())
        let fields = metadata
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\(key)=\(value.description.replacingOccurrences(of: "\n", with: " "))"
            }
            .sorted()
            .joined(separator: " ")
        let suffix = fields.isEmpty ? "" : " \(fields)"
        let line = "\(timestamp) [\(level)] \(message)\(suffix)\n"

        queue.async {
            do {
                let url = fileURL
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                rotateIfNeeded(url)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                } else {
                    try line.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                NSLog("MenuBarSpotify file log failed: %@", error.localizedDescription)
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              size > maxBytes else {
            return
        }

        let rotatedURL = url.deletingLastPathComponent().appendingPathComponent("MenuBarSpotify.previous.log")
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}

private extension ISO8601DateFormatter {
    static let menuBarSpotify: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
