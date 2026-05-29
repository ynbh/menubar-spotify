import Foundation
import Observation

@MainActor
@Observable
final class SpotifyStore {
    var config = SpotifyConfig()
    var isSignedIn = false
    private(set) var isBusy = false
    var errorMessage = ""
    var searchQuery = ""
    var searchResults: [SpotifyTrack] = []
    var recentTracks: [SpotifyTrack] = []
    var playlists: [SpotifyPlaylist] = []
    var isLoadingPlaylists = false
    var selectedPlaylist: SpotifyPlaylist?
    var playlistTracks: [SpotifyTrack] = []
    var playlistTracksHasMore = false
    var isLoadingPlaylistTracks = false
    var isLoadingMorePlaylistTracks = false
    var playback: SpotifyPlaybackState?
    var isLyricsPresented = false
    var lyrics: LyricsResult?
    var lyricsStatus = ""
    private var pendingLyricsTrackID: String?
    private var playbackProjection = PlaybackProjection()
    private var playlistTracksNextPath: String?
    var devices: [SpotifyDevice] = []
    var selectedDeviceID: String?
    var webPlaybackDeviceID: String?
    var webPlaybackStatus = "Starting player..."
    var webPlaybackReloadID = UUID()
    var playbackDeviceID: String? {
        activeDeviceTransferID() ?? playback?.device?.id ?? selectedDeviceID
    }

    private var busyCount = 0
    private var tokenRefreshTask: Task<String, Error>?
    private var playbackCommandTail: Task<Void, Never>?
    private var webPlaybackDisconnectHandler: (() -> Void)?
    private var pendingDeviceTransferID: String?
    private var pendingDeviceTransferExpiresAt: Date?

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

    func registerWebPlayback(disconnect: @escaping () -> Void) {
        webPlaybackDisconnectHandler = disconnect
    }

    func handleOpenURL(_ url: URL) {
        _ = authService.handleCallbackURL(url)
    }

    func bootstrap() async {
        do {
            config = try configStore.load()
            isSignedIn = config.refreshToken != nil || config.accessToken != nil
            if isSignedIn {
                try await refreshNowPlaying()
                await loadDevices()
                await loadRecentTracks()
                await loadPlaylists()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        await runBusy {
            config = try await authService.signIn(config: config)
            try configStore.save(config)
            isSignedIn = true
            self.errorMessage = ""
            try await refreshNowPlaying()
            await loadDevices()
            await loadRecentTracks()
            await loadPlaylists()
        }
    }

    func refreshSession() async {
        await runBusy {
            if config.refreshToken != nil {
                tokenRefreshTask?.cancel()
                tokenRefreshTask = nil
                config = try await authService.refresh(config: config)
                try configStore.save(config)
                isSignedIn = true
            } else {
                config = try await authService.signIn(config: config)
                try configStore.save(config)
                isSignedIn = true
            }

            webPlaybackDisconnectHandler?()
            webPlaybackDeviceID = nil
            webPlaybackStatus = "Starting player..."
            webPlaybackReloadID = UUID()
            errorMessage = ""

            try await refreshNowPlaying()
            await loadDevices()
            await loadRecentTracks()
            await loadPlaylists()
        }
    }

    func signOut() {
        webPlaybackDisconnectHandler?()
        config.accessToken = nil
        config.refreshToken = nil
        config.expiresAt = nil
        isSignedIn = false
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        clearLibraryState()
        do {
            try configStore.save(config)
            self.errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshNowPlaying() async throws {
        applyPlaybackState(try await self.apiClient.currentPlayback())
    }

    func loadDevices() async {
        await runBusy {
            devices = try await self.apiClient.devices()
            if selectedDeviceID == nil {
                selectedDeviceID = webPlaybackDeviceID ?? playback?.device?.id ?? devices.first(where: \.isActive)?.id
            }
        }
    }

    func selectDevice(_ device: SpotifyDevice) async {
        guard let id = device.id else {
            return
        }

        holdDeviceTransfer(to: device)
        await runBusy {
            do {
                try await self.apiClient.transferPlayback(to: id, play: playback?.isPlaying == true)
                try await refreshNowPlaying()
                if activeDeviceTransferID() == id {
                    clearDeviceTransferHold()
                }
            } catch {
                clearDeviceTransferHold()
                try? await refreshNowPlaying()
                throw error
            }
        }
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
                searchResults = try await self.apiClient.searchTracks(query: query)
                cache.storeSearchResults(searchResults, for: query)
            }
            errorMessage = ""
        }
    }

    func loadRecentTracks() async {
        await runBusy {
            if let cached = cache.recentTracks() {
                recentTracks = cached.deduplicatedByTrackID()
            } else {
                recentTracks = try await self.apiClient.recentlyPlayedTracks()
                cache.storeRecentTracks(recentTracks)
            }
        }
    }

    func loadPlaylists() async {
        isLoadingPlaylists = playlists.isEmpty
        defer { isLoadingPlaylists = false }

        await runBusy {
            if let cached = cache.playlists() {
                playlists = cached
            } else {
                playlists = try await self.apiClient.playlists()
                cache.storePlaylists(playlists)
            }
        }
    }

    func openPlaylist(_ playlist: SpotifyPlaylist) async {
        selectedPlaylist = playlist
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = true

        if let cached = cache.playlistTracks(for: playlist.id) {
            playlistTracks = cached
            isLoadingPlaylistTracks = false
            return
        }

        await runBusy {
            let page = try await self.apiClient.playlistTracksPage(playlistID: playlist.id)
            playlistTracks = page.tracks
            playlistTracksNextPath = page.nextPath
            playlistTracksHasMore = page.nextPath != nil
            if page.nextPath == nil {
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        }
        isLoadingPlaylistTracks = false
    }

    func closePlaylist() {
        selectedPlaylist = nil
        playlistTracks = []
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = false
    }

    func loadMorePlaylistTracks() async {
        guard let playlist = selectedPlaylist,
              let nextPath = playlistTracksNextPath,
              !isLoadingMorePlaylistTracks else {
            return
        }

        isLoadingMorePlaylistTracks = true
        defer { isLoadingMorePlaylistTracks = false }

        do {
            let page = try await self.apiClient.playlistTracksPage(playlistID: playlist.id, startingAt: nextPath)
            playlistTracks.append(contentsOf: page.tracks)
            playlistTracksNextPath = page.nextPath
            playlistTracksHasMore = page.nextPath != nil
            if page.nextPath == nil {
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playTrack(_ track: SpotifyTrack) async {
        startProjectedPlayback(
            playbackProjection.startSingleTrack(track, device: playback?.device),
            track: track
        )

        runPlaybackCommand {
            try await self.apiClient.play(trackURI: track.uri, preferredDeviceID: self.preferredPlaybackDeviceID)
            self.errorMessage = ""
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func playPlaylistTrack(_ track: SpotifyTrack) async {
        guard let playlist = selectedPlaylist else {
            await playTrack(track)
            return
        }
        startProjectedPlayback(
            playbackProjection.startPlaylistTrack(track, context: playlistTracks, device: playback?.device),
            track: track
        )

        runPlaybackCommand {
            try await self.apiClient.play(contextURI: playlist.uri, trackURI: track.uri, preferredDeviceID: self.preferredPlaybackDeviceID)
            self.errorMessage = ""
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func togglePlayback() async {
        let shouldPlay = playback?.isPlaying != true
        playbackProjection.setPlaying(shouldPlay, playback: &playback)

        runPlaybackCommand {
            if shouldPlay {
                try await self.apiClient.resume(preferredDeviceID: self.preferredPlaybackDeviceID)
            } else {
                try await self.apiClient.pause()
            }
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func skipNext() async {
        if let projectedPlayback = playbackProjection.skipNext(from: playback) {
            startProjectedPlayback(projectedPlayback, track: projectedPlayback.item)
        }

        runPlaybackCommand {
            try await self.apiClient.skipNext()
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func skipPrevious() async {
        if let projectedPlayback = playbackProjection.skipPrevious(from: playback) {
            startProjectedPlayback(projectedPlayback, track: projectedPlayback.item)
        }

        runPlaybackCommand {
            try await self.apiClient.skipPrevious()
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func seek(to fraction: Double) async {
        guard let durationMs = playback?.item?.durationMs else {
            return
        }
        let clampedFraction = min(max(fraction, 0), 1)
        let positionMs = Int(Double(durationMs) * clampedFraction)
        playbackProjection.seek(to: positionMs, playback: &playback)

        runPlaybackCommand {
            try await self.apiClient.seek(to: positionMs)
            Task { try? await self.refreshNowPlayingWithRetry() }
        }
    }

    func addToQueue(_ track: SpotifyTrack) async {
        playbackProjection.addToQueue(track)

        runPlaybackCommand {
            try await self.apiClient.addToQueue(trackURI: track.uri, preferredDeviceID: self.preferredPlaybackDeviceID)
            self.errorMessage = ""
        }
    }

    func accessTokenForWebPlayback() async -> String? {
        try? await validAccessToken()
    }

    func webPlaybackReady(deviceID: String) async {
        webPlaybackDeviceID = deviceID
        if selectedDeviceID == nil {
            selectedDeviceID = deviceID
        }
        webPlaybackStatus = "MenuBar player ready."
        do {
            try await self.apiClient.transferPlayback(to: deviceID)
            await loadDevices()
            try await refreshNowPlaying()
        } catch {
            webPlaybackStatus = error.localizedDescription
        }
    }

    func webPlaybackFailed(_ message: String) {
        webPlaybackStatus = message
    }

    func refreshNowPlayingQuietly() async {
        applyPlaybackState(try? await apiClient.currentPlayback())
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

        if let tokenRefreshTask {
            return try await tokenRefreshTask.value
        }

        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else {
                throw SpotifyError.authFailed("App state is unavailable.")
            }
            defer { self.tokenRefreshTask = nil }

            self.config = try await self.authService.refresh(config: self.config)
            try self.configStore.save(self.config)
            guard let token = self.config.accessToken else {
                throw SpotifyError.authFailed("Spotify access token is missing.")
            }
            return token
        }

        tokenRefreshTask = task
        return try await task.value
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
        isLoadingPlaylists = false
        selectedPlaylist = nil
        playlistTracks = []
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = false
        isLoadingMorePlaylistTracks = false
        devices = []
        selectedDeviceID = nil
        pendingDeviceTransferID = nil
        pendingDeviceTransferExpiresAt = nil
        playback = nil
        isLyricsPresented = false
        lyrics = nil
        lyricsStatus = ""
        pendingLyricsTrackID = nil
        playbackProjection.clear()
        cache.clear()
        webPlaybackDeviceID = nil
        webPlaybackStatus = "Starting player..."
        webPlaybackReloadID = UUID()
        playbackCommandTail?.cancel()
        playbackCommandTail = nil
        webPlaybackDisconnectHandler = nil
    }

    private var preferredPlaybackDeviceID: String? {
        selectedDeviceID ?? webPlaybackDeviceID
    }

    private func startProjectedPlayback(_ projectedPlayback: SpotifyPlaybackState, track: SpotifyTrack?) {
        playback = projectedPlayback
        guard let track else {
            return
        }
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
        guard playbackProjection.allows(state, replacing: playback) else {
            return
        }

        let heldDeviceID = activeDeviceTransferID()
        let incomingDeviceID = state?.device?.id
        playback = state

        if let heldDeviceID, incomingDeviceID != heldDeviceID {
            selectedDeviceID = heldDeviceID
            playback?.device = device(for: heldDeviceID)
        } else if let deviceID = incomingDeviceID {
            selectedDeviceID = deviceID
            if deviceID == heldDeviceID {
                clearDeviceTransferHold()
            }
        }
        playbackProjection.accept(state)
    }

    private func holdDeviceTransfer(to device: SpotifyDevice) {
        selectedDeviceID = device.id
        pendingDeviceTransferID = device.id
        pendingDeviceTransferExpiresAt = Date().addingTimeInterval(4)
        playback?.device = device
    }

    private func activeDeviceTransferID() -> String? {
        if let expiresAt = pendingDeviceTransferExpiresAt, Date() > expiresAt {
            clearDeviceTransferHold()
        }
        return pendingDeviceTransferID
    }

    private func clearDeviceTransferHold() {
        pendingDeviceTransferID = nil
        pendingDeviceTransferExpiresAt = nil
    }

    private func device(for id: String) -> SpotifyDevice? {
        if id == webPlaybackDeviceID {
            return SpotifyDevice(
                id: id,
                name: "MenuBar Spotify",
                type: "Computer",
                isActive: true,
                isRestricted: false
            )
        }
        return devices.first { $0.id == id } ?? playback?.device
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

    private func beginBusy() {
        busyCount += 1
        isBusy = busyCount > 0
    }

    private func endBusy() {
        busyCount = max(0, busyCount - 1)
        isBusy = busyCount > 0
    }

    private func runPlaybackCommand(_ operation: @escaping @MainActor () async throws -> Void) {
        let previousCommand = playbackCommandTail
        playbackCommandTail = Task { @MainActor [weak self] in
            await previousCommand?.value
            guard let self, !Task.isCancelled else {
                return
            }

            self.beginBusy()
            defer { self.endBusy() }

            do {
                try await operation()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func runBusy(_ operation: () async throws -> Void) async {
        beginBusy()
        defer { endBusy() }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
