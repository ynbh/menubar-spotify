import Foundation

struct PlaybackReconciliation {
    private var selectedTrackID: String?
    private var selectedTrackExpiresAt: Date?
    private var seekPositionMs: Int?
    private var seekExpiresAt: Date?
    private var expectedIsPlaying: Bool?
    private var isPlayingExpiresAt: Date?
    private var skippedTrackID: String?
    private var skippedTrackExpiresAt: Date?

    mutating func holdTrack(_ trackID: String) {
        selectedTrackID = trackID
        selectedTrackExpiresAt = Date().addingTimeInterval(4)
        seekPositionMs = nil
        seekExpiresAt = nil
        expectedIsPlaying = nil
        isPlayingExpiresAt = nil
        skippedTrackID = nil
        skippedTrackExpiresAt = nil
    }

    mutating func holdSeek(at positionMs: Int) {
        seekPositionMs = positionMs
        seekExpiresAt = Date().addingTimeInterval(3)
    }

    mutating func holdPlaybackState(isPlaying: Bool) {
        expectedIsPlaying = isPlaying
        isPlayingExpiresAt = Date().addingTimeInterval(3)
    }

    mutating func holdSkip(of trackID: String) {
        skippedTrackID = trackID
        skippedTrackExpiresAt = Date().addingTimeInterval(3)
    }

    mutating func allows(_ incoming: SpotifyPlaybackState?, replacing current: SpotifyPlaybackState?) -> Bool {
        clearExpiredHolds()

        if let selectedTrackID, incoming?.item?.id != selectedTrackID {
            return false
        }

        if let skippedTrackID, incoming?.item?.id == skippedTrackID {
            return false
        }

        if let expectedIsPlaying, incoming?.isPlaying != expectedIsPlaying {
            return false
        }

        guard let seekPositionMs else {
            return true
        }

        guard incoming?.item?.id == current?.item?.id,
              let progressMs = incoming?.progressMs else {
            return false
        }

        let elapsedMs = seekExpiresAt.map { max(0, Int((Date().timeIntervalSince($0) + 3.0) * 1000)) } ?? 0
        let maxProgressMs = seekPositionMs + elapsedMs + 1000

        return progressMs >= seekPositionMs - 750 && progressMs <= maxProgressMs
    }

    mutating func accept(_ state: SpotifyPlaybackState?) {
        if state?.item?.id == selectedTrackID {
            selectedTrackID = nil
            selectedTrackExpiresAt = nil
        }

        if let skippedTrackID, state?.item?.id != skippedTrackID {
            self.skippedTrackID = nil
            skippedTrackExpiresAt = nil
        }

        if let expectedIsPlaying, state?.isPlaying == expectedIsPlaying {
            self.expectedIsPlaying = nil
            isPlayingExpiresAt = nil
        }

        guard let seekPositionMs,
              let progressMs = state?.progressMs,
              progressMs >= seekPositionMs - 750 else {
            return
        }

        self.seekPositionMs = nil
        seekExpiresAt = nil
    }

    mutating func clear() {
        selectedTrackID = nil
        selectedTrackExpiresAt = nil
        seekPositionMs = nil
        seekExpiresAt = nil
        expectedIsPlaying = nil
        isPlayingExpiresAt = nil
        skippedTrackID = nil
        skippedTrackExpiresAt = nil
    }

    private mutating func clearExpiredHolds() {
        if let selectedTrackExpiresAt, Date() > selectedTrackExpiresAt {
            selectedTrackID = nil
            self.selectedTrackExpiresAt = nil
        }

        if let seekExpiresAt, Date() > seekExpiresAt {
            seekPositionMs = nil
            self.seekExpiresAt = nil
        }

        if let isPlayingExpiresAt, Date() > isPlayingExpiresAt {
            expectedIsPlaying = nil
            self.isPlayingExpiresAt = nil
        }

        if let skippedTrackExpiresAt, Date() > skippedTrackExpiresAt {
            skippedTrackID = nil
            self.skippedTrackExpiresAt = nil
        }
    }
}
