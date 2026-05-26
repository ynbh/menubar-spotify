import Foundation

struct SpotifyCache {
    private let ttl: TimeInterval
    private let recentTTL: TimeInterval
    private var playlistsEntry: CacheEntry<[SpotifyPlaylist]>?
    private var recentTracksEntry: CacheEntry<[SpotifyTrack]>?
    private var lyricsEntries: [String: CacheEntry<LyricsResult>] = [:]
    private var searchEntries: [String: CacheEntry<[SpotifyTrack]>] = [:]
    private var playlistTrackEntries: [String: CacheEntry<[SpotifyTrack]>] = [:]

    init(ttl: TimeInterval = 300, recentTTL: TimeInterval = 60) {
        self.ttl = ttl
        self.recentTTL = recentTTL
    }

    mutating func playlists() -> [SpotifyPlaylist]? {
        playlistsEntry?.value(ifValidFor: ttl)
    }

    mutating func storePlaylists(_ playlists: [SpotifyPlaylist]) {
        playlistsEntry = CacheEntry(value: playlists)
    }

    mutating func recentTracks() -> [SpotifyTrack]? {
        recentTracksEntry?.value(ifValidFor: recentTTL)
    }

    mutating func storeRecentTracks(_ tracks: [SpotifyTrack]) {
        recentTracksEntry = CacheEntry(value: tracks)
    }

    mutating func lyrics(for trackID: String) -> LyricsResult? {
        lyricsEntries[trackID]?.value(ifValidFor: ttl)
    }

    mutating func storeLyrics(_ lyrics: LyricsResult, for trackID: String) {
        lyricsEntries[trackID] = CacheEntry(value: lyrics)
    }

    mutating func searchResults(for query: String) -> [SpotifyTrack]? {
        searchEntries[normalized(query)]?.value(ifValidFor: ttl)
    }

    mutating func storeSearchResults(_ tracks: [SpotifyTrack], for query: String) {
        searchEntries[normalized(query)] = CacheEntry(value: tracks)
    }

    mutating func playlistTracks(for playlistID: String) -> [SpotifyTrack]? {
        playlistTrackEntries[playlistID]?.value(ifValidFor: ttl)
    }

    mutating func storePlaylistTracks(_ tracks: [SpotifyTrack], for playlistID: String) {
        playlistTrackEntries[playlistID] = CacheEntry(value: tracks)
    }

    mutating func clear() {
        playlistsEntry = nil
        recentTracksEntry = nil
        lyricsEntries.removeAll()
        searchEntries.removeAll()
        playlistTrackEntries.removeAll()
    }

    private func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct CacheEntry<Value> {
    let value: Value
    let savedAt = Date()

    func value(ifValidFor ttl: TimeInterval) -> Value? {
        guard Date().timeIntervalSince(savedAt) < ttl else {
            return nil
        }
        return value
    }
}
