import Foundation

struct PlaybackProjection {
    private var reconciliation = PlaybackReconciliation()
    private var activeContext: [SpotifyTrack] = []
    private var queuedTracks: [SpotifyTrack] = []

    mutating func startSingleTrack(_ track: SpotifyTrack, device: SpotifyDevice?) -> SpotifyPlaybackState {
        activeContext = [track]
        queuedTracks = []
        return start(track, device: device)
    }

    mutating func startPlaylistTrack(
        _ track: SpotifyTrack,
        context: [SpotifyTrack],
        device: SpotifyDevice?
    ) -> SpotifyPlaybackState {
        activeContext = context
        queuedTracks = []
        return start(track, device: device)
    }

    mutating func setPlaying(_ isPlaying: Bool, playback: inout SpotifyPlaybackState?) {
        reconciliation.holdPlaybackState(isPlaying: isPlaying)
        playback?.setPlaying(isPlaying)
    }

    mutating func seek(to positionMs: Int, playback: inout SpotifyPlaybackState?) {
        reconciliation.holdSeek(at: positionMs)
        playback?.seek(to: positionMs)
    }

    mutating func addToQueue(_ track: SpotifyTrack) {
        queuedTracks.append(track)
    }

    mutating func skipNext(from playback: SpotifyPlaybackState?) -> SpotifyPlaybackState? {
        if let queuedTrack = queuedTracks.first {
            queuedTracks.removeFirst()
            return start(queuedTrack, device: playback?.device)
        }

        guard let nextTrack = adjacentTrack(from: playback, forward: true) else {
            holdCurrentTrackSkip(from: playback)
            return nil
        }

        holdCurrentTrackSkip(from: playback)
        return start(nextTrack, device: playback?.device)
    }

    mutating func skipPrevious(from playback: SpotifyPlaybackState?) -> SpotifyPlaybackState? {
        guard let previousTrack = adjacentTrack(from: playback, forward: false) else {
            holdCurrentTrackSkip(from: playback)
            return nil
        }

        holdCurrentTrackSkip(from: playback)
        return start(previousTrack, device: playback?.device)
    }

    mutating func allows(_ incoming: SpotifyPlaybackState?, replacing current: SpotifyPlaybackState?) -> Bool {
        reconciliation.allows(incoming, replacing: current)
    }

    mutating func accept(_ playback: SpotifyPlaybackState?) {
        reconciliation.accept(playback)
        if let track = playback?.item {
            syncContext(for: track)
        }
    }

    mutating func clear() {
        reconciliation.clear()
        activeContext = []
        queuedTracks = []
    }

    private mutating func start(_ track: SpotifyTrack, device: SpotifyDevice?) -> SpotifyPlaybackState {
        reconciliation.holdTrack(track.id)
        syncContext(for: track)
        return SpotifyPlaybackState(
            isPlaying: true,
            progressMs: 0,
            item: track,
            device: device
        )
    }

    private mutating func holdCurrentTrackSkip(from playback: SpotifyPlaybackState?) {
        guard let trackID = playback?.item?.id else {
            return
        }
        reconciliation.holdSkip(of: trackID)
    }

    private mutating func adjacentTrack(from playback: SpotifyPlaybackState?, forward: Bool) -> SpotifyTrack? {
        guard let currentTrack = playback?.item,
              let index = activeContext.firstIndex(where: { $0.id == currentTrack.id }) else {
            return nil
        }

        let adjacentIndex = forward ? index + 1 : index - 1
        guard activeContext.indices.contains(adjacentIndex) else {
            return nil
        }
        return activeContext[adjacentIndex]
    }

    private mutating func syncContext(for track: SpotifyTrack) {
        if activeContext.contains(where: { $0.id == track.id }) {
            return
        }

        if activeContext.count <= 1 {
            activeContext = [track]
        }
    }
}
