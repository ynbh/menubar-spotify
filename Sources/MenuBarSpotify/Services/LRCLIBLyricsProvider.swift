import Foundation

struct LRCLIBLyricsProvider {
    private let searchURL = URL(string: "https://lrclib.net/api/search")!

    func lyrics(for track: SpotifyTrack) async throws -> LyricsResult {
        try await searchedLyrics(for: track)
    }

    private func searchedLyrics(for track: SpotifyTrack) async throws -> LyricsResult {
        let payloads: [LRCLIBResponse] = try await fetch(url: searchLookupURL(for: track))
        guard let payload = payloads.first(where: { $0.matches(track: track) }) else {
            throw LyricsError.notFound
        }
        return try result(from: payload, for: track)
    }

    private func searchLookupURL(for track: SpotifyTrack) throws -> URL {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = lookupItems(for: track)
        guard let url = components.url else {
            throw LyricsError.unavailable
        }
        return url
    }

    private func lookupItems(for track: SpotifyTrack) -> [URLQueryItem] {
        [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artists.first?.name ?? track.artistLine),
            URLQueryItem(name: "album_name", value: track.album?.name)
        ].filter { $0.value?.isEmpty == false }
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LyricsError.unavailable
        }
        guard http.statusCode != 404 else {
            throw LyricsError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LyricsError.unavailable
        }
        return try JSONDecoder.spotify.decode(T.self, from: data)
    }

    private func result(from payload: LRCLIBResponse, for track: SpotifyTrack) throws -> LyricsResult {
        guard payload.matches(track: track) else {
            throw LyricsError.notFound
        }
        return LyricsResult(
            trackID: track.id,
            plainLyrics: payload.plainLyrics,
            syncedLines: parseSyncedLyrics(payload.syncedLyrics)
        )
    }

    private func parseSyncedLyrics(_ text: String?) -> [SyncedLyricLine] {
        guard let text, !text.isEmpty else {
            return []
        }

        return text
            .split(separator: "\n")
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> SyncedLyricLine? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else {
            return nil
        }

        let timestamp = String(line[line.index(after: line.startIndex)..<close])
        let lyricText = line[line.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let time = parseTimestamp(timestamp), !lyricText.isEmpty else {
            return nil
        }
        return SyncedLyricLine(time: time, text: lyricText)
    }

    private func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }
}

private struct LRCLIBResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let plainLyrics: String?
    let syncedLyrics: String?

    func matches(track: SpotifyTrack) -> Bool {
        let requestedTrack = normalized(track.name)
        let returnedTrack = normalized(trackName ?? "")
        guard !returnedTrack.isEmpty, returnedTrack == requestedTrack else {
            return false
        }

        let requestedArtists = track.artists.map { normalized($0.name) }
        let returnedArtist = normalized(artistName ?? "")
        guard !returnedArtist.isEmpty else {
            return true
        }
        return requestedArtists.contains { returnedArtist.contains($0) || $0.contains(returnedArtist) }
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LyricsError: LocalizedError {
    case notFound
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Lyrics unavailable for this song."
        case .unavailable:
            return "Could not load lyrics."
        }
    }
}
