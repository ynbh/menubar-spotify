import Foundation

struct SpotifyAPIClient {
    private static let baseURL = URL(string: "https://api.spotify.com/v1/")!

    var accessTokenProvider: () async throws -> String

    func currentPlayback() async throws -> SpotifyPlaybackState? {
        try await requestOptional("me/player")
    }

    func devices() async throws -> [SpotifyDevice] {
        let response: DevicesResponse = try await request("me/player/devices")
        return response.devices
    }

    func searchTracks(query: String) async throws -> [SpotifyTrack] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }
        let encoded = trimmedQuery.urlQueryEncoded
        let response: SearchTracksResponse = try await request("search?q=\(encoded)&type=track&limit=10")
        return response.tracks.items
    }

    func recentlyPlayedTracks() async throws -> [SpotifyTrack] {
        let response: RecentlyPlayedResponse = try await request("me/player/recently-played?limit=20")
        return response.items.map(\.track).deduplicatedByTrackID()
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        try await paginatePlaylists(startingAt: "me/playlists?limit=50")
    }

    func savedTracksSummary() async throws -> PlaylistTrackSummary {
        let response: SavedTracksResponse = try await request("me/tracks?limit=1")
        return PlaylistTrackSummary(total: response.total)
    }

    func savedTracksPage(startingAt path: String? = nil) async throws -> PlaylistTracksPage {
        let requestPath = path ?? "me/tracks?limit=50"
        let response: SavedTracksResponse = try await request(requestPath)
        return PlaylistTracksPage(
            tracks: response.items.map(\.track),
            nextPath: response.next.flatMap(Self.apiPath(from:))
        )
    }

    func playlistTracksPage(playlistID: String, startingAt path: String? = nil) async throws -> PlaylistTracksPage {
        let requestPath = path ?? "playlists/\(playlistID)/tracks?limit=100"
        let response: PlaylistTracksResponse = try await request(requestPath)
        return PlaylistTracksPage(
            tracks: response.items.compactMap(\.track),
            nextPath: response.next.flatMap(Self.apiPath(from:))
        )
    }

    func deletePlaylist(id playlistID: String) async throws {
        let _: EmptyResponse = try await request("playlists/\(playlistID)/followers", method: "DELETE")
    }

    func transferPlayback(to deviceID: String, play: Bool = false) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "device_ids": [deviceID],
            "play": play
        ])
        let _: EmptyResponse = try await request("me/player", method: "PUT", body: data)
    }

    func resume(preferredDeviceID: String? = nil) async throws {
        guard let deviceID = try await resolvedDeviceID(preferredDeviceID: preferredDeviceID) else {
            throw SpotifyError.noActiveDevice
        }
        let _: EmptyResponse = try await request(
            "me/player/play?device_id=\(deviceID.urlQueryEncoded)",
            method: "PUT"
        )
    }

    func pause(preferredDeviceID: String? = nil) async throws {
        let deviceQuery = try await deviceQuery(preferredDeviceID: preferredDeviceID)
        let _: EmptyResponse = try await request("me/player/pause\(deviceQuery)", method: "PUT")
    }

    func skipNext(preferredDeviceID: String? = nil) async throws {
        let deviceQuery = try await deviceQuery(preferredDeviceID: preferredDeviceID)
        let _: EmptyResponse = try await request("me/player/next\(deviceQuery)", method: "POST")
    }

    func skipPrevious(preferredDeviceID: String? = nil) async throws {
        let deviceQuery = try await deviceQuery(preferredDeviceID: preferredDeviceID)
        let _: EmptyResponse = try await request("me/player/previous\(deviceQuery)", method: "POST")
    }

    func seek(to positionMs: Int, preferredDeviceID: String? = nil) async throws {
        guard let deviceID = try await resolvedDeviceID(preferredDeviceID: preferredDeviceID) else {
            throw SpotifyError.noActiveDevice
        }
        let _: EmptyResponse = try await request(
            "me/player/seek?position_ms=\(positionMs)&device_id=\(deviceID.urlQueryEncoded)",
            method: "PUT"
        )
    }

    func addToQueue(trackURI: String, preferredDeviceID: String? = nil) async throws {
        guard let deviceID = try await resolvedDeviceID(preferredDeviceID: preferredDeviceID) else {
            throw SpotifyError.noActiveDevice
        }
        let _: EmptyResponse = try await request(
            "me/player/queue?uri=\(trackURI.urlQueryEncoded)&device_id=\(deviceID.urlQueryEncoded)",
            method: "POST"
        )
    }

    func play(trackURI: String, preferredDeviceID: String? = nil) async throws {
        try await play(body: ["uris": [trackURI]], preferredDeviceID: preferredDeviceID)
    }

    func play(contextURI: String, trackURI: String? = nil, preferredDeviceID: String? = nil) async throws {
        var body: [String: Any] = ["context_uri": contextURI]
        if let trackURI {
            body["offset"] = ["uri": trackURI]
        }
        try await play(body: body, preferredDeviceID: preferredDeviceID)
    }

    private func paginatePlaylists(startingAt path: String) async throws -> [SpotifyPlaylist] {
        var playlists: [SpotifyPlaylist] = []
        var nextPath: String? = path

        while let currentPath = nextPath {
            let response: PlaylistsResponse = try await request(currentPath)
            playlists.append(contentsOf: response.items.compactMap { $0 })
            nextPath = response.next.flatMap(Self.apiPath(from:))
        }

        return playlists
    }

    static func apiPath(from nextURL: String) -> String? {
        guard let url = URL(string: nextURL) else {
            return nil
        }

        var path = url.path
        if path.hasPrefix("/v1/") {
            path.removeFirst(4)
        } else if path.hasPrefix("/") {
            path.removeFirst()
        }

        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        return path.isEmpty ? nil : path
    }

    private func play(body: [String: Any], preferredDeviceID: String?) async throws {
        guard let deviceID = try await resolvedDeviceID(preferredDeviceID: preferredDeviceID) else {
            throw SpotifyError.noActiveDevice
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        let _: EmptyResponse = try await request(
            "me/player/play?device_id=\(deviceID.urlQueryEncoded)",
            method: "PUT",
            body: data
        )
    }

    private func resolvedDeviceID(preferredDeviceID: String?) async throws -> String? {
        if let preferredDeviceID {
            return preferredDeviceID
        }
        return try await playbackTargetDevice()?.id
    }

    private func deviceQuery(preferredDeviceID: String?) async throws -> String {
        guard let deviceID = try await resolvedDeviceID(preferredDeviceID: preferredDeviceID) else {
            throw SpotifyError.noActiveDevice
        }
        return "?device_id=\(deviceID.urlQueryEncoded)"
    }

    private func playbackTargetDevice() async throws -> SpotifyDevice? {
        if let device = try await currentPlayback()?.device, !device.isRestricted {
            return device
        }

        let devices = try await devices().filter { !$0.isRestricted }
        if let active = devices.first(where: \.isActive) {
            return active
        }
        if devices.count == 1 {
            return devices[0]
        }
        return devices.first { $0.type == "Computer" } ?? devices.first
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await rawRequest(path, method: method, body: body, allowNoContent: T.self == EmptyResponse.self)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decode(data)
    }

    private func requestOptional<T: Decodable>(_ path: String) async throws -> T? {
        let token = try await accessTokenProvider()
        var request = URLRequest(url: url(for: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.apiFailed("Spotify returned a non-HTTP response.")
        }
        if http.statusCode == 204 || http.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown Spotify error"
            throw SpotifyError.apiFailed(body)
        }
        return try decode(data)
    }

    private func rawRequest(_ path: String, method: String, body: Data?, allowNoContent: Bool) async throws -> Data {
        let token = try await accessTokenProvider()
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.apiFailed("Spotify returned a non-HTTP response.")
        }
        if allowNoContent, http.statusCode == 204 {
            return Data()
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown Spotify error"
            if http.statusCode == 404 || body.contains("NO_ACTIVE_DEVICE") {
                throw SpotifyError.noActiveDevice
            }
            throw SpotifyError.apiFailed(body)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder.spotify.decode(T.self, from: data)
        } catch {
            throw SpotifyError.apiFailed("Could not read Spotify response: \(error.localizedDescription)")
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let startedAt = Date()
        let method = request.httpMethod ?? "GET"
        let path = request.url.map { url in
            guard let query = url.query, !query.isEmpty else {
                return url.path
            }
            return "\(url.path)?\(query)"
        } ?? "unknown"
        AppLog.event("spotify request started", metadata: ["method": method, "path": path])
        do {
            let result = try await URLSession.shared.data(for: request)
            let status = (result.1 as? HTTPURLResponse)?.statusCode
            AppLog.event(
                "spotify request finished",
                metadata: [
                    "method": method,
                    "path": path,
                    "status": status,
                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                ]
            )
            return result
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                AppLog.event("spotify request cancelled", metadata: ["method": method, "path": path])
                throw CancellationError()
            }
            AppLog.error(
                "spotify request failed",
                error,
                metadata: [
                    "method": method,
                    "path": path,
                    "durationMs": Int(Date().timeIntervalSince(startedAt) * 1000)
                ]
            )
            throw SpotifyError.networkFailure(from: error) ?? error
        }
    }

    private func url(for path: String) -> URL {
        URL(string: path, relativeTo: Self.baseURL)!
    }
}

struct EmptyResponse: Decodable {}

private struct DevicesResponse: Decodable {
    let devices: [SpotifyDevice]
}

enum SpotifyError: LocalizedError {
    case missingConfig(String)
    case authFailed(String)
    case apiFailed(String)
    case networkFailed(String)
    case noActiveDevice

    var errorDescription: String? {
        switch self {
        case .missingConfig(let message), .authFailed(let message), .apiFailed(let message), .networkFailed(let message):
            return message
        case .noActiveDevice:
            return "Player is not ready."
        }
    }

    var isNetworkFailure: Bool {
        if case .networkFailed = self {
            return true
        }
        return false
    }

    static func networkFailure(from error: Error) -> SpotifyError? {
        guard let urlError = error as? URLError else {
            return nil
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return .networkFailed("No internet connection. Could not connect to Spotify.")
        case .timedOut:
            return .networkFailed("Spotify connection timed out.")
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .networkFailed("Could not reach Spotify.")
        case .networkConnectionLost:
            return .networkFailed("Spotify connection was lost.")
        default:
            return .networkFailed("Could not connect to Spotify: \(urlError.localizedDescription)")
        }
    }
}
