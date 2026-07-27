import Foundation

struct PlaybackProjection {
    mutating func startSingleTrack(_ track: SpotifyTrack, device: SpotifyDevice?) -> SpotifyPlaybackState {
        start(track, device: device)
    }

    mutating func startPlaylistTrack(
        _ track: SpotifyTrack,
        context: [SpotifyTrack],
        device: SpotifyDevice?
    ) -> SpotifyPlaybackState {
        _ = context
        return start(track, device: device)
    }

    mutating func setPlaying(
        _ isPlaying: Bool,
        playback: inout SpotifyPlaybackState?,
        at uptime: TimeInterval = PlaybackClock.now
    ) {
        playback?.setPlaying(isPlaying, at: uptime)
    }

    mutating func seek(
        to positionMs: Int,
        playback: inout SpotifyPlaybackState?,
        at uptime: TimeInterval = PlaybackClock.now
    ) {
        playback?.seek(to: positionMs, at: uptime)
    }

    mutating func clear() {}

    private func start(_ track: SpotifyTrack, device: SpotifyDevice?) -> SpotifyPlaybackState {
        SpotifyPlaybackState(
            isPlaying: true,
            progressMs: 0,
            item: track,
            device: device
        )
    }
}
