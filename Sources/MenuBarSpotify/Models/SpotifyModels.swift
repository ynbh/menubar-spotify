import Foundation

struct SpotifyConfig {
    var clientID: String = ""
    var clientSecret: String = ""
    var redirectURI: String = "spotify-menubar://callback"
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

struct SpotifyImage: Decodable, Hashable {
    let url: URL
    let height: Int?
    let width: Int?
}

struct SpotifyArtist: Decodable, Hashable {
    let name: String
}

struct SpotifyAlbum: Decodable, Hashable {
    let name: String?
    let images: [SpotifyImage]
}

struct SpotifyTrack: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, album
        case durationMs = "duration_ms"
    }

    var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    var artworkURL: URL? {
        album?.images.sorted { ($0.width ?? 0) > ($1.width ?? 0) }.first?.url
    }

    var durationText: String {
        let totalSeconds = durationMs / 1000
        return "\(totalSeconds / 60):" + String(format: "%02d", totalSeconds % 60)
    }
}

struct SpotifyPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]
    let tracks: PlaylistTrackSummary

    var artworkURL: URL? {
        images.sorted { ($0.width ?? 0) > ($1.width ?? 0) }.first?.url
    }
}

extension SpotifyPlaylist {
    enum CodingKeys: String, CodingKey {
        case id, name, uri, images, tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uri = try container.decode(String.self, forKey: .uri)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images) ?? []
        tracks = try container.decode(PlaylistTrackSummary.self, forKey: .tracks)
    }
}

struct PlaylistTrackSummary: Decodable, Hashable {
    let total: Int
}

struct SpotifyDevice: Decodable, Identifiable, Hashable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let isRestricted: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isRestricted = "is_restricted"
    }
}

struct SpotifyPlaybackState: Decodable {
    var isPlaying: Bool
    var progressMs: Int?
    let item: SpotifyTrack?
    var device: SpotifyDevice?
    var receivedAt = Date()

    enum CodingKeys: String, CodingKey {
        case item, device
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
    }

    var estimatedProgressMs: Int {
        guard isPlaying, let progressMs else {
            return progressMs ?? 0
        }
        let elapsed = Int(Date().timeIntervalSince(receivedAt) * 1000)
        return min(progressMs + elapsed, item?.durationMs ?? progressMs + elapsed)
    }

    mutating func setPlaying(_ playing: Bool) {
        isPlaying = playing
        receivedAt = Date()
    }

    mutating func seek(to positionMs: Int) {
        progressMs = max(0, min(positionMs, item?.durationMs ?? positionMs))
        receivedAt = Date()
    }
}

struct SearchTracksResponse: Decodable {
    let tracks: Paging<SpotifyTrack>
}

struct RecentlyPlayedResponse: Decodable {
    let items: [RecentlyPlayedItem]
}

struct RecentlyPlayedItem: Decodable {
    let track: SpotifyTrack
}

struct LyricsResult: Hashable {
    let trackID: String
    let plainLyrics: String?
    let syncedLines: [SyncedLyricLine]

    var isEmpty: Bool {
        plainLyrics?.isEmpty != false && syncedLines.isEmpty
    }
}

struct SyncedLyricLine: Hashable, Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

extension Array where Element == SpotifyTrack {
    func deduplicatedByTrackID() -> [SpotifyTrack] {
        var seenTrackIDs = Set<String>()
        return filter { track in
            seenTrackIDs.insert(track.id).inserted
        }
    }
}

struct Paging<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int
    let next: String?
}

struct PlaylistsResponse: Decodable {
    let items: [SpotifyPlaylist?]
    let next: String?
}

struct PlaylistTracksResponse: Decodable {
    let items: [PlaylistTrackItem]
    let next: String?
}

struct PlaylistTrackItem: Decodable, Identifiable {
    var id: String { track?.id ?? itemID }
    private let itemID: String
    let track: SpotifyTrack?

    enum CodingKeys: String, CodingKey {
        case track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decodeIfPresent(SpotifyTrack.self, forKey: .track)
        itemID = track?.id ?? UUID().uuidString
    }
}

struct PlaylistTracksPage {
    let tracks: [SpotifyTrack]
    let nextPath: String?
}
