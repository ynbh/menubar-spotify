import Foundation

struct ConfigStore {
    let url: URL

    static func discover() -> ConfigStore {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SPOTIFY_CONFIG_PATH"], !path.isEmpty {
            return ConfigStore(url: URL(fileURLWithPath: path))
        }

        if let bundledConfig = Bundle.main.url(forResource: "spotify", withExtension: "config") {
            return ConfigStore(url: bundledConfig)
        }

        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledWorkspaceConfig = bundleRoot.appendingPathComponent(".config")
        if FileManager.default.fileExists(atPath: bundledWorkspaceConfig.path) {
            return ConfigStore(url: bundledWorkspaceConfig)
        }

        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return ConfigStore(url: current.appendingPathComponent(".config"))
    }

    func load() throws -> SpotifyConfig {
        var config = SpotifyConfig()
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.event("config file missing", metadata: ["path": url.path])
            return config
        }

        AppLog.event("config load started", metadata: ["path": url.path])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? UInt64, size > 100_000 {
            throw SpotifyError.missingConfig("Spotify config is unexpectedly large: \(url.path)")
        }

        let data = try Data(contentsOf: url, options: [])
        guard let content = String(data: data, encoding: .utf8) else {
            throw SpotifyError.missingConfig("Spotify config is not valid UTF-8: \(url.path)")
        }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "SPOTIFY_CLIENT_ID":
                config.clientID = value
            case "SPOTIFY_REDIRECT_URI":
                config.redirectURI = value
            case "SPOTIFY_ACCESS_TOKEN":
                config.accessToken = value
            case "SPOTIFY_REFRESH_TOKEN":
                config.refreshToken = value
            case "SPOTIFY_EXPIRES_AT":
                if let timestamp = TimeInterval(value) {
                    config.expiresAt = Date(timeIntervalSince1970: timestamp)
                }
            default:
                break
            }
        }
        AppLog.event(
            "config load finished",
            metadata: [
                "path": url.path,
                "hasClientID": !config.clientID.isEmpty,
                "hasRefreshToken": config.refreshToken != nil,
                "hasAccessToken": config.accessToken != nil
            ]
        )
        return config
    }

    func save(_ config: SpotifyConfig) throws {
        var lines = [
            "SPOTIFY_CLIENT_ID=\(config.clientID)",
            "SPOTIFY_REDIRECT_URI=\(config.redirectURI)"
        ]

        if let accessToken = config.accessToken {
            lines.append("SPOTIFY_ACCESS_TOKEN=\(accessToken)")
        }
        if let refreshToken = config.refreshToken {
            lines.append("SPOTIFY_REFRESH_TOKEN=\(refreshToken)")
        }
        if let expiresAt = config.expiresAt {
            lines.append("SPOTIFY_EXPIRES_AT=\(Int(expiresAt.timeIntervalSince1970))")
        }

        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
