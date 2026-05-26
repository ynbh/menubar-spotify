import Foundation

struct PlaybackReconciliation {
    private var selectedTrackID: String?
    private var selectedTrackExpiresAt: Date?
    private var seekPositionMs: Int?
    private var seekExpiresAt: Date?

    mutating func holdTrack(_ trackID: String) {
        selectedTrackID = trackID
        selectedTrackExpiresAt = Date().addingTimeInterval(4)
        seekPositionMs = nil
        seekExpiresAt = nil
    }

    mutating func holdSeek(at positionMs: Int) {
        seekPositionMs = positionMs
        seekExpiresAt = Date().addingTimeInterval(3)
    }

    mutating func allows(_ incoming: SpotifyPlaybackState?, replacing current: SpotifyPlaybackState?) -> Bool {
        clearExpiredHolds()

        if let selectedTrackID, incoming?.item?.id != selectedTrackID {
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
    }
}
