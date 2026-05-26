import Foundation
import Observation

@MainActor
@Observable
final class SpotifyStore {
    var config = SpotifyConfig()
    var isSignedIn = false
    var isBusy = false
    var statusMessage = ""
    var searchQuery = ""
    var searchResults: [SpotifyTrack] = []
    var recentTracks: [SpotifyTrack] = []
    var playlists: [SpotifyPlaylist] = []
    var selectedPlaylist: SpotifyPlaylist?
    var playlistTracks: [SpotifyTrack] = []
    var playback: SpotifyPlaybackState?
    var now = Date()
    var isLyricsPresented = false
    var lyrics: LyricsResult?
    var lyricsStatus = ""
    private var pendingLyricsTrackID: String?
    private var playbackReconciliation = PlaybackReconciliation()
    private var activeQueue: [SpotifyTrack] = []
    var webPlaybackDeviceID: String?
    var webPlaybackStatus = "Starting player..."

    private let configStore = ConfigStore.discover()
    private let authService = SpotifyAuthService()
    private let lyricsProvider = LRCLIBLyricsProvider()
    private var cache = SpotifyCache()

    private var apiClient: SpotifyAPIClient {
        SpotifyAPIClient { [weak self] in
            guard let self else { throw SpotifyError.authFailed("App state is unavailable.") }
            return try await self.validAccessToken()
        }
    }

    func bootstrap() async {
        do {
            config = try configStore.load()
            isSignedIn = config.refreshToken != nil || config.accessToken != nil
            if isSignedIn {
                try await refreshNowPlaying()
                await loadRecentTracks()
                await loadPlaylists()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signIn() async {
        await runBusy {
            config = try await authService.signIn(config: config)
            try configStore.save(config)
            isSignedIn = true
            try await refreshNowPlaying()
            await loadRecentTracks()
            await loadPlaylists()
            statusMessage = "Signed in."
        }
    }

    func signOut() {
        config.accessToken = nil
        config.refreshToken = nil
        config.expiresAt = nil
        isSignedIn = false
        clearLibraryState()
        do {
            try configStore.save(config)
            statusMessage = "Signed out."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshNowPlaying() async throws {
        applyPlaybackState(try await apiClient.currentPlayback())
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await loadRecentTracks()
            return
        }

        await runBusy {
            if let cached = cache.searchResults(for: query) {
                searchResults = cached
            } else {
                searchResults = try await apiClient.searchTracks(query: query)
                cache.storeSearchResults(searchResults, for: query)
            }
            statusMessage = searchResults.isEmpty ? "No songs found." : ""
        }
    }

    func loadRecentTracks() async {
        await runBusy {
            if let cached = cache.recentTracks() {
                recentTracks = cached
            } else {
                recentTracks = try await apiClient.recentlyPlayedTracks()
                cache.storeRecentTracks(recentTracks)
            }
        }
    }

    func loadPlaylists() async {
        await runBusy {
            if let cached = cache.playlists() {
                playlists = cached
            } else {
                playlists = try await apiClient.playlists()
                cache.storePlaylists(playlists)
            }
        }
    }

    func openPlaylist(_ playlist: SpotifyPlaylist) async {
        selectedPlaylist = playlist
        await runBusy {
            if let cached = cache.playlistTracks(for: playlist.id) {
                playlistTracks = cached
            } else {
                playlistTracks = try await apiClient.playlistTracks(playlistID: playlist.id)
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        }
    }

    func playTrack(_ track: SpotifyTrack) async {
        if searchResults.contains(where: { $0.id == track.id }) {
            activeQueue = searchResults
        } else if recentTracks.contains(where: { $0.id == track.id }) {
            activeQueue = recentTracks
        } else {
            activeQueue = [track]
        }
        startLocalPlayback(for: track)

        await runBusy {
            try await apiClient.play(trackURI: track.uri, preferredDeviceID: webPlaybackDeviceID)
            statusMessage = "Playing \(track.name)"
            Task { try? await refreshNowPlayingWithRetry() }
        }
    }

    func playPlaylistTrack(_ track: SpotifyTrack) async {
        guard let playlist = selectedPlaylist else {
            await playTrack(track)
            return
        }
        activeQueue = playlistTracks
        startLocalPlayback(for: track)

        await runBusy {
            try await apiClient.play(contextURI: playlist.uri, trackURI: track.uri, preferredDeviceID: webPlaybackDeviceID)
            statusMessage = "Playing \(track.name)"
            Task { try? await refreshNowPlayingWithRetry() }
        }
    }

    func togglePlayback() async {
        await runBusy {
            if playback?.isPlaying == true {
                playbackReconciliation.holdPlaybackState(isPlaying: false)
                try await apiClient.pause()
                playback?.setPlaying(false)
            } else {
                playbackReconciliation.holdPlaybackState(isPlaying: true)
                try await apiClient.resume(preferredDeviceID: webPlaybackDeviceID)
                playback?.setPlaying(true)
            }
            Task { try? await refreshNowPlayingWithRetry() }
        }
    }

    func skipNext() async {
        if let currentTrackID = playback?.item?.id {
            playbackReconciliation.holdSkip(of: currentTrackID)
            
            if let currentIndex = activeQueue.firstIndex(where: { $0.id == currentTrackID }),
               currentIndex + 1 < activeQueue.count {
                let nextTrack = activeQueue[currentIndex + 1]
                startLocalPlayback(for: nextTrack)
            }
        }
        await runBusy {
            try await apiClient.skipNext()
            try await refreshNowPlayingWithRetry()
        }
    }

    func skipPrevious() async {
        if let currentTrackID = playback?.item?.id {
            playbackReconciliation.holdSkip(of: currentTrackID)
            
            if let currentIndex = activeQueue.firstIndex(where: { $0.id == currentTrackID }),
               currentIndex - 1 >= 0 {
                let prevTrack = activeQueue[currentIndex - 1]
                startLocalPlayback(for: prevTrack)
            }
        }
        await runBusy {
            try await apiClient.skipPrevious()
            try await refreshNowPlayingWithRetry()
        }
    }

    func seek(to fraction: Double) async {
        guard let durationMs = playback?.item?.durationMs else {
            return
        }
        let clampedFraction = min(max(fraction, 0), 1)
        let positionMs = Int(Double(durationMs) * clampedFraction)
        playbackReconciliation.holdSeek(at: positionMs)
        playback?.seek(to: positionMs)

        await runBusy {
            try await apiClient.seek(to: positionMs)
            Task { try? await refreshNowPlayingWithRetry() }
        }
    }

    func accessTokenForWebPlayback() async -> String? {
        do {
            return try await validAccessToken()
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func webPlaybackReady(deviceID: String) async {
        webPlaybackDeviceID = deviceID
        webPlaybackStatus = "MenuBar player ready."
        do {
            try await apiClient.transferPlayback(to: deviceID)
            try await refreshNowPlaying()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func webPlaybackFailed(_ message: String) {
        webPlaybackStatus = message
        statusMessage = message
    }

    func refreshNowPlayingQuietly() async {
        do {
            applyPlaybackState(try await apiClient.currentPlayback())
        } catch {
            if playback == nil {
                statusMessage = error.localizedDescription
            }
        }
    }

    func tickClock() {
        now = Date()
    }

    func toggleLyrics() {
        isLyricsPresented.toggle()
        if isLyricsPresented {
            Task { await loadLyricsForCurrentTrack() }
        }
    }

    func loadLyricsForCurrentTrack() async {
        guard let track = playback?.item else {
            lyrics = nil
            lyricsStatus = "No song playing."
            return
        }

        if lyrics?.trackID == track.id || pendingLyricsTrackID == track.id {
            return
        }

        await runBusy {
            pendingLyricsTrackID = track.id
            lyricsStatus = "Loading lyrics..."
            if let cached = cache.lyrics(for: track.id) {
                applyLyrics(cached, for: track.id)
            } else {
                let fetchedLyrics = try await lyricsProvider.lyrics(for: track)
                cache.storeLyrics(fetchedLyrics, for: track.id)
                applyLyrics(fetchedLyrics, for: track.id)
            }
            pendingLyricsTrackID = nil
            if lyrics?.trackID == track.id {
                lyricsStatus = lyrics?.isEmpty == true ? "Lyrics unavailable for this song." : ""
            }
        }
    }

    private func validAccessToken() async throws -> String {
        if let token = config.accessToken, let expiresAt = config.expiresAt, expiresAt > Date() {
            return token
        }
        config = try await authService.refresh(config: config)
        try configStore.save(config)
        guard let token = config.accessToken else {
            throw SpotifyError.authFailed("Spotify access token is missing.")
        }
        return token
    }

    private func refreshNowPlayingWithRetry() async throws {
        let maxAttempts = 5
        for attempt in 0..<maxAttempts {
            try await refreshNowPlaying()
            if playback?.item != nil {
                return
            }
            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private func clearLibraryState() {
        searchResults = []
        recentTracks = []
        playlists = []
        selectedPlaylist = nil
        playlistTracks = []
        playback = nil
        isLyricsPresented = false
        lyrics = nil
        lyricsStatus = ""
        pendingLyricsTrackID = nil
        playbackReconciliation.clear()
        activeQueue = []
        cache.clear()
        webPlaybackDeviceID = nil
        webPlaybackStatus = "Starting player..."
    }

    private func startLocalPlayback(for track: SpotifyTrack) {
        playbackReconciliation.holdTrack(track.id)
        playback = SpotifyPlaybackState(
            isPlaying: true,
            progressMs: 0,
            item: track,
            device: playback?.device
        )
        prefetchLyrics(for: track)

        guard isLyricsPresented else {
            return
        }
        lyrics = nil
        lyricsStatus = "Loading lyrics..."
        pendingLyricsTrackID = nil
        Task { await loadLyricsForCurrentTrack() }
    }

    private func applyPlaybackState(_ state: SpotifyPlaybackState?) {
        guard playbackReconciliation.allows(state, replacing: playback) else {
            return
        }

        playback = state
        playbackReconciliation.accept(state)
    }

    private func prefetchLyrics(for track: SpotifyTrack) {
        guard cache.lyrics(for: track.id) == nil else {
            return
        }

        Task {
            do {
                let fetchedLyrics = try await lyricsProvider.lyrics(for: track)
                cache.storeLyrics(fetchedLyrics, for: track.id)
                if isLyricsPresented {
                    applyLyrics(fetchedLyrics, for: track.id)
                }
            } catch {
                if isLyricsPresented, playback?.item?.id == track.id {
                    lyricsStatus = error.localizedDescription
                }
            }
        }
    }

    private func applyLyrics(_ result: LyricsResult, for trackID: String) {
        guard playback?.item?.id == trackID else {
            return
        }
        lyrics = result
    }

    private func runBusy(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
