import Foundation
import Observation

@MainActor
@Observable
final class SpotifyStore {
    var config = SpotifyConfig()
    var isSignedIn = false
    private(set) var isBusy = false
    private(set) var isDeviceBusy = false
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
    private(set) var scrubPreview: PlaybackScrubPreview?
    var isLyricsPresented = false
    var lyrics: LyricsResult?
    var lyricsStatus = ""
    private var pendingLyricsTrackID: String?
    private var playbackProjection = PlaybackProjection()
    private var playbackTimeline = PlaybackTimeline()
    private var playlistTracksNextPath: String?
    var devices: [SpotifyDevice] = []
    var selectedDeviceID: String?
    var webPlaybackDeviceID: String?
    var webPlaybackStatus = "Starting player..."
    var webPlaybackNeedsActivation = true
    var webPlaybackReloadID = UUID()
    var playbackDeviceID: String? {
        activeDeviceTransferID() ?? playback?.device?.id ?? selectedDeviceID
    }

    private var busyCount = 0
    private var deviceBusyCount = 0
    private var tokenRefreshTask: Task<String, Error>?
    private var playbackCommandTail: Task<Void, Never>?
    private var seekCommandTask: Task<Void, Never>?
    private var playbackRefreshLoopTask: Task<Void, Never>?
    private var webPlaybackDisconnectHandler: (() -> Void)?
    private var lastWebPlaybackReadyAt: TimeInterval?
    private var pendingDeviceTransferID: String?
    private var pendingDeviceTransferExpiresAt: TimeInterval?
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap = false
    private var sessionGeneration = 0
    private var playbackRefreshRequestID = 0
    private var appliedPlaybackRefreshRequestID = 0
    private var searchRequestID = 0
    private var playlistOpenRequestID = 0
    private var playlistPageRequestID = 0
    private var lyricsRequestID = 0
    private var trackPlaybackRequestID = 0

    private let configStore = ConfigStore.discover()
    private let authService = SpotifyAuthService()
    private let lyricsProvider = LRCLIBLyricsProvider()
    private var cache = SpotifyCache()
    @ObservationIgnored lazy var webPlaybackController = WebPlaybackController()

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
        if didBootstrap {
            AppLog.event("bootstrap skipped; already completed")
            return
        }

        if let bootstrapTask {
            AppLog.event("bootstrap joined existing task")
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor in
            await runBootstrap()
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func runBootstrap() async {
        let generation = sessionGeneration
        AppLog.event("bootstrap started")
        do {
            config = try configStore.load()
            guard generation == sessionGeneration else {
                AppLog.event("bootstrap discarded after session changed")
                return
            }
            isSignedIn = config.refreshToken != nil || config.accessToken != nil
            AppLog.event(
                "config loaded",
                metadata: [
                    "isSignedIn": isSignedIn,
                    "hasRefreshToken": config.refreshToken != nil,
                    "hasAccessToken": config.accessToken != nil,
                    "expiresAt": config.expiresAt?.timeIntervalSince1970
                ]
            )
            if isSignedIn {
                startPlaybackRefreshLoop()
                webPlaybackController.attach(store: self, reloadID: webPlaybackReloadID)
                try await refreshNowPlaying()
                guard generation == sessionGeneration else { return }
                await loadDevices()
                guard generation == sessionGeneration else { return }
                await loadRecentTracks()
                guard generation == sessionGeneration else { return }
                await loadPlaylists()
            }
            didBootstrap = true
            AppLog.event("bootstrap finished", metadata: ["isSignedIn": isSignedIn])
        } catch {
            AppLog.error("bootstrap failed", error)
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        sessionGeneration += 1
        let generation = sessionGeneration
        await runBusy {
            config = try await authService.signIn(config: config)
            guard generation == sessionGeneration else { return }
            try configStore.save(config)
            isSignedIn = true
            startPlaybackRefreshLoop()
            webPlaybackController.attach(store: self, reloadID: webPlaybackReloadID)
            self.errorMessage = ""
            try await refreshNowPlaying()
            await loadDevices()
            await loadRecentTracks()
            await loadPlaylists()
        }
    }

    func refreshSession() async {
        sessionGeneration += 1
        let generation = sessionGeneration
        await runBusy {
            if config.refreshToken != nil {
                tokenRefreshTask?.cancel()
                tokenRefreshTask = nil
                config = try await authService.refresh(config: config)
            } else {
                config = try await authService.signIn(config: config)
            }
            guard generation == sessionGeneration else { return }
            try configStore.save(config)
            isSignedIn = true
            startPlaybackRefreshLoop()

            webPlaybackDisconnectHandler?()
            webPlaybackDeviceID = nil
            webPlaybackNeedsActivation = true
            webPlaybackStatus = "Starting player..."
            webPlaybackReloadID = UUID()
            webPlaybackController.attach(store: self, reloadID: webPlaybackReloadID)
            errorMessage = ""

            try await refreshNowPlaying()
            await loadDevices()
            await loadRecentTracks()
            await loadPlaylists()
        }
    }

    func signOut() {
        sessionGeneration += 1
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

    @discardableResult
    private func refreshNowPlaying() async throws -> PlaybackRefreshResult {
        AppLog.event("refresh now playing started")
        playbackRefreshRequestID += 1
        let requestID = playbackRefreshRequestID
        let state = try await self.apiClient.currentPlayback()
        let application = applyPlaybackState(state, fromRefreshRequest: requestID)
        AppLog.event(
            "refresh now playing finished",
            metadata: [
                "requestID": requestID,
                "responseHasPlayback": state != nil,
                "responseIsPlaying": state?.isPlaying,
                "responseProgressMs": state?.progressMs,
                "application": application.description,
                "hasPlayback": playback != nil,
                "track": playback?.item?.name,
                "device": playback?.device?.name
            ]
        )
        return PlaybackRefreshResult(state: state, application: application)
    }

    func loadDevices() async {
        await runDeviceBusy("load devices") {
            devices = try await self.apiClient.devices()
            if selectedDeviceID == nil {
                selectedDeviceID = webPlaybackDeviceID ?? playback?.device?.id ?? devices.first(where: \.isActive)?.id
            }
            AppLog.event(
                "devices loaded",
                metadata: [
                    "count": devices.count,
                    "selectedDeviceID": selectedDeviceID,
                    "webPlaybackDeviceID": webPlaybackDeviceID
                ]
            )
        }
    }

    func selectDevice(_ device: SpotifyDevice) async {
        guard let id = device.id else {
            return
        }

        holdDeviceTransfer(to: device)
        await runDeviceBusy("select device") {
            do {
                try await self.apiClient.transferPlayback(to: id, play: playback?.isPlaying == true)
                try await refreshNowPlaying()
                if activeDeviceTransferID() == id {
                    clearDeviceTransferHold()
                }
            } catch {
                clearDeviceTransferHold()
                _ = try? await refreshNowPlaying()
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

        searchRequestID += 1
        let requestID = searchRequestID
        await runBusy {
            if let cached = cache.searchResults(for: query) {
                guard requestID == searchRequestID,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                searchResults = cached
            } else {
                let results = try await self.apiClient.searchTracks(query: query)
                cache.storeSearchResults(results, for: query)
                guard requestID == searchRequestID,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                searchResults = results
            }
            errorMessage = ""
        }
    }

    func clearSearch() async {
        searchRequestID += 1
        searchQuery = ""
        searchResults = []
        await loadRecentTracks()
    }

    func loadRecentTracks() async {
        await runBusy("load recent tracks") {
            if let cached = cache.recentTracks() {
                recentTracks = cached.deduplicatedByTrackID()
            } else {
                recentTracks = try await self.apiClient.recentlyPlayedTracks()
                cache.storeRecentTracks(recentTracks)
            }
            AppLog.event("recent tracks loaded", metadata: ["count": recentTracks.count])
        }
    }

    func loadPlaylists() async {
        isLoadingPlaylists = playlists.isEmpty
        defer { isLoadingPlaylists = false }

        await runBusy("load playlists") {
            let likedSongs = await self.likedSongsPlaylist()

            if let cached = cache.playlists() {
                playlists = [likedSongs] + cached
            } else {
                let spotifyPlaylists = try await self.apiClient.playlists()
                playlists = [likedSongs] + spotifyPlaylists
                cache.storePlaylists(spotifyPlaylists)
            }
            AppLog.event("playlists loaded", metadata: ["count": playlists.count])
        }
    }

    func openPlaylist(_ playlist: SpotifyPlaylist) async {
        playlistOpenRequestID += 1
        playlistPageRequestID += 1
        let requestID = playlistOpenRequestID
        selectedPlaylist = playlist
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = true

        if let cached = cache.playlistTracks(for: playlist.id) {
            guard requestID == playlistOpenRequestID,
                  selectedPlaylist?.id == playlist.id else {
                return
            }
            playlistTracks = cached
            isLoadingPlaylistTracks = false
            return
        }

        await runBusy {
            let page = try await self.tracksPage(for: playlist)
            guard requestID == playlistOpenRequestID,
                  selectedPlaylist?.id == playlist.id else {
                return
            }
            playlistTracks = page.tracks
            playlistTracksNextPath = page.nextPath
            playlistTracksHasMore = page.nextPath != nil
            if page.nextPath == nil {
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        }
        if requestID == playlistOpenRequestID {
            isLoadingPlaylistTracks = false
        }
    }

    func closePlaylist() {
        playlistOpenRequestID += 1
        playlistPageRequestID += 1
        selectedPlaylist = nil
        playlistTracks = []
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = false
    }

    func deleteSelectedPlaylist() async {
        guard let playlist = selectedPlaylist else {
            return
        }
        guard !playlist.isLikedSongs else {
            closePlaylist()
            return
        }

        playlists.removeAll { $0.id == playlist.id }
        closePlaylist()
        cache.removePlaylist(id: playlist.id)

        await runBusy {
            try await self.apiClient.deletePlaylist(id: playlist.id)
            self.errorMessage = ""
        }
    }

    func loadMorePlaylistTracks() async {
        guard let playlist = selectedPlaylist,
              let nextPath = playlistTracksNextPath,
              !isLoadingMorePlaylistTracks else {
            return
        }

        playlistPageRequestID += 1
        let requestID = playlistPageRequestID
        isLoadingMorePlaylistTracks = true
        defer { isLoadingMorePlaylistTracks = false }

        do {
            let page = try await self.tracksPage(for: playlist, startingAt: nextPath)
            guard requestID == playlistPageRequestID,
                  selectedPlaylist?.id == playlist.id,
                  playlistTracksNextPath == nextPath else {
                return
            }
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
        trackPlaybackRequestID += 1
        let requestID = trackPlaybackRequestID
        let intent = beginPlaybackIntent(.playTrack(trackURI: track.uri))
        startProjectedPlayback(
            playbackProjection.startSingleTrack(track, device: playback?.device),
            track: track
        )

        runLatestPlaybackCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            guard self.isCurrentTrackPlaybackRequest(requestID), self.playbackTimeline.isCurrent(intentID: intent.id) else {
                return
            }
            try await self.apiClient.play(trackURI: track.uri, preferredDeviceID: self.preferredPlaybackDeviceID)
            self.errorMessage = ""
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    func playPlaylistTrack(_ track: SpotifyTrack) async {
        guard let playlist = selectedPlaylist else {
            await playTrack(track)
            return
        }
        guard !playlist.isLikedSongs else {
            await playTrack(track)
            return
        }
        let context = playlistTracks
        trackPlaybackRequestID += 1
        let requestID = trackPlaybackRequestID
        let intent = beginPlaybackIntent(.playTrack(trackURI: track.uri))
        startProjectedPlayback(
            playbackProjection.startPlaylistTrack(track, context: context, device: playback?.device),
            track: track
        )

        runLatestPlaybackCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            guard self.isCurrentTrackPlaybackRequest(requestID), self.playbackTimeline.isCurrent(intentID: intent.id) else {
                return
            }
            try await self.apiClient.play(
                contextURI: playlist.uri,
                trackURI: track.uri,
                preferredDeviceID: self.preferredPlaybackDeviceID
            )
            self.errorMessage = ""
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    private func tracksPage(for playlist: SpotifyPlaylist, startingAt path: String? = nil) async throws -> PlaylistTracksPage {
        if playlist.isLikedSongs {
            return try await apiClient.savedTracksPage(startingAt: path)
        }
        return try await apiClient.playlistTracksPage(playlistID: playlist.id, startingAt: path)
    }

    private func likedSongsPlaylist() async -> SpotifyPlaylist {
        do {
            let summary = try await apiClient.savedTracksSummary()
            return SpotifyPlaylist.likedSongs(total: summary.total)
        } catch {
            AppLog.error("liked songs summary failed", error)
            return SpotifyPlaylist.likedSongs(total: 0)
        }
    }

    func togglePlayback() async {
        let shouldPlay = playback?.isPlaying != true
        let intent = beginPlaybackIntent(
            .setPlaying(isPlaying: shouldPlay, trackURI: playback?.item?.uri)
        )
        playbackProjection.setPlaying(shouldPlay, playback: &playback)

        runPlaybackCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            try await self.setPlaybackPlaying(shouldPlay)
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    func skipNext() async {
        let intent = beginPlaybackIntent(.skip(fromTrackURI: playback?.item?.uri))
        runPlaybackCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            try await self.performSkip(next: true)
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    func skipPrevious() async {
        let intent = beginPlaybackIntent(.skip(fromTrackURI: playback?.item?.uri))
        runPlaybackCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            try await self.performSkip(next: false)
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    func playbackProgressMs(at uptime: TimeInterval = PlaybackClock.now) -> Int {
        if let scrubPreview {
            return scrubPreview.positionMs
        }
        return playback?.estimatedProgressMs(at: uptime) ?? 0
    }

    func updateScrubPreview(to fraction: Double) {
        guard let track = playback?.item, track.durationMs > 0 else {
            scrubPreview = nil
            return
        }

        let clampedFraction = min(max(fraction, 0), 1)
        if scrubPreview?.trackURI != track.uri {
            scrubPreview = PlaybackScrubPreview(
                trackURI: track.uri,
                durationMs: track.durationMs,
                positionMs: 0
            )
        }
        scrubPreview?.positionMs = Int(Double(track.durationMs) * clampedFraction)
    }

    func cancelScrubPreview() {
        scrubPreview = nil
    }

    func commitScrubPreview() {
        guard let preview = scrubPreview,
              playback?.item?.uri == preview.trackURI else {
            scrubPreview = nil
            return
        }
        seek(to: preview.fraction, expectedTrackURI: preview.trackURI)
        scrubPreview = nil
    }

    func seek(to fraction: Double, expectedTrackURI: String? = nil) {
        guard let track = playback?.item,
              track.durationMs > 0,
              expectedTrackURI == nil || expectedTrackURI == track.uri else {
            return
        }
        let clampedFraction = min(max(fraction, 0), 1)
        let positionMs = Int(Double(track.durationMs) * clampedFraction)
        let intent = beginPlaybackIntent(
            .seek(trackURI: track.uri, positionMs: positionMs, durationMs: track.durationMs)
        )
        playbackProjection.seek(to: positionMs, playback: &playback)

        runLatestSeekCommand(intentID: intent.id) {
            try await self.waitForPlaybackDeviceIfNeeded()
            guard self.playback?.item?.uri == track.uri else {
                self.playbackTimeline.clearIntent(intent.id)
                return
            }
            try await self.performSeek(to: positionMs)
            try await self.refreshNowPlayingWithRetry(intentID: intent.id)
        }
    }

    func addToQueue(_ track: SpotifyTrack) async {
        runPlaybackCommand {
            try await self.waitForPlaybackDeviceIfNeeded()
            try await self.apiClient.addToQueue(trackURI: track.uri, preferredDeviceID: self.preferredPlaybackDeviceID)
            self.errorMessage = ""
        }
    }

    func accessTokenForWebPlayback() async -> String? {
        do {
            return try await validAccessToken()
        } catch {
            surface(error)
            return nil
        }
    }

    func webPlaybackGenerationStarted(_ generation: Int) {
        playbackTimeline.startWebGeneration(generation)
        AppLog.event("web playback generation started", metadata: ["generation": generation])
    }

    func webPlaybackReady(deviceID: String, generation: Int) async {
        guard generation == playbackTimeline.webGeneration else {
            return
        }
        let now = PlaybackClock.now
        if webPlaybackDeviceID == deviceID,
           let lastWebPlaybackReadyAt,
           now - lastWebPlaybackReadyAt < 2 {
            AppLog.event("duplicate web playback ready ignored", metadata: ["deviceID": deviceID])
            return
        }

        lastWebPlaybackReadyAt = now
        webPlaybackDeviceID = deviceID
        webPlaybackNeedsActivation = true
        selectedDeviceID = deviceID
        if let webPlaybackDevice = device(for: deviceID) {
            holdDeviceTransfer(to: webPlaybackDevice)
        }
        webPlaybackStatus = "Connecting MenuBar player..."
        AppLog.event("web playback ready", metadata: ["deviceID": deviceID])
        await runDeviceBusy("web playback ready") {
            do {
                try await self.transferPlaybackToWebPlayerWithRetry(deviceID: deviceID)
                guard self.webPlaybackDeviceID == deviceID,
                      generation == self.playbackTimeline.webGeneration else { return }
                let refreshedDevices = try await self.apiClient.devices()
                guard self.webPlaybackDeviceID == deviceID,
                      generation == self.playbackTimeline.webGeneration else { return }
                self.devices = refreshedDevices
                self.selectedDeviceID = deviceID
                self.webPlaybackStatus = "MenuBar player ready."
                try await refreshNowPlaying()
            } catch {
                guard generation == self.playbackTimeline.webGeneration,
                      self.webPlaybackDeviceID == deviceID else {
                    return
                }
                self.webPlaybackStatus = error.localizedDescription
                throw error
            }
        }
    }

    func webPlaybackStateChanged(
        generation: Int,
        sequence: Int,
        paused: Bool,
        positionMs: Int,
        durationMs: Int?,
        trackURI: String?,
        eventTimestampMs: Int
    ) {
        guard generation == playbackTimeline.webGeneration,
              let activeWebPlaybackDeviceID = webPlaybackDeviceID,
              playbackDeviceID == activeWebPlaybackDeviceID else {
            return
        }

        AppLog.event(
            "web playback player state",
            metadata: [
                "generation": generation,
                "sequence": sequence,
                "paused": paused,
                "positionMs": positionMs,
                "durationMs": durationMs,
                "trackURI": trackURI
            ]
        )

        guard let trackURI else {
            _ = playbackTimeline.observeWebEvent(
                generation: generation,
                sequence: sequence,
                eventTimestampMs: eventTimestampMs
            )
            return
        }

        guard let current = playback, current.item?.uri == trackURI else {
            let acknowledgedIntentID = playbackTimeline.observeWebTrackTransition(
                generation: generation,
                sequence: sequence,
                trackURI: trackURI,
                eventTimestampMs: eventTimestampMs
            )
            AppLog.event(
                "web playback track transition observed",
                metadata: ["trackURI": trackURI, "intentID": acknowledgedIntentID]
            )
            Task { @MainActor [weak self] in
                _ = try? await self?.refreshNowPlaying()
            }
            return
        }

        var webState = current
        webState.isPlaying = !paused
        webState.progressMs = max(0, min(positionMs, current.item?.durationMs ?? positionMs))
        webState.device = device(for: activeWebPlaybackDeviceID) ?? current.device
        webState.sourceTimestampMs = eventTimestampMs
        webState.receivedAtUptime = PlaybackClock.now

        let application = playbackTimeline.applyWebState(
            webState,
            generation: generation,
            sequence: sequence,
            eventTimestampMs: eventTimestampMs,
            replacing: playback
        )
        guard case .applied(let acceptedState, _) = application else {
            AppLog.event("web playback state not applied", metadata: ["reason": application.description])
            return
        }
        reconcileScrubPreview(with: acceptedState)
        playback = acceptedState
        selectedDeviceID = activeWebPlaybackDeviceID
    }

    func webPlaybackWentOffline(deviceID: String? = nil, message: String = "MenuBar player went offline.") {
        guard deviceID == nil || deviceID == webPlaybackDeviceID else {
            return
        }

        AppLog.error("web playback went offline", metadata: ["deviceID": deviceID, "message": message])
        webPlaybackDisconnected(deviceID: deviceID)
        restartWebPlayback()
    }

    func webPlaybackFailed(_ message: String) {
        AppLog.error("web playback failed", metadata: ["message": message])
        if message.localizedCaseInsensitiveContains("invalid token scopes") {
            let scopeMessage = "Spotify sign-in is missing playback scopes. Sign out and sign in again."
            webPlaybackStatus = scopeMessage
            errorMessage = scopeMessage
        } else {
            webPlaybackStatus = message
        }
    }

    func webPlaybackAudioActivated() {
        webPlaybackNeedsActivation = false
        errorMessage = ""
        AppLog.event("web playback audio activated")
    }

    func webPlaybackAudioActivationFailed(_ message: String) {
        webPlaybackNeedsActivation = true
        webPlaybackStatus = message
        AppLog.error("web playback audio activation failed", metadata: ["message": message])
    }

    func webPlaybackAutoplayFailed() {
        webPlaybackNeedsActivation = true
        AppLog.error("web playback autoplay failed")
    }

    func webPlaybackDisconnected(deviceID: String? = nil) {
        guard deviceID == nil || deviceID == webPlaybackDeviceID else {
            return
        }

        AppLog.event("web playback disconnected", metadata: ["deviceID": deviceID ?? webPlaybackDeviceID])
        if selectedDeviceID == webPlaybackDeviceID {
            selectedDeviceID = playback?.device?.id == webPlaybackDeviceID ? nil : playback?.device?.id
        }
        webPlaybackDeviceID = nil
        lastWebPlaybackReadyAt = nil
        webPlaybackNeedsActivation = true
        webPlaybackStatus = "Starting player..."
    }

    private func startPlaybackRefreshLoop() {
        guard playbackRefreshLoopTask == nil else {
            return
        }
        playbackRefreshLoopTask = Task { @MainActor [weak self] in
            while let self, self.isSignedIn, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.isSignedIn else {
                    break
                }
                await self.refreshNowPlayingQuietly()
            }
        }
    }

    func refreshNowPlayingQuietly() async {
        guard !isDeviceBusy else {
            AppLog.event("quiet refresh skipped during device operation")
            return
        }

        do {
            try await refreshNowPlaying()
        } catch SpotifyError.noActiveDevice {
            AppLog.event("quiet refresh found no active device")
            handlePlaybackUnavailable()
        } catch {
            if let spotifyError = error as? SpotifyError, spotifyError.isNetworkFailure {
                AppLog.error("quiet refresh network failure", spotifyError)
                surface(spotifyError)
            }
            return
        }
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

        lyricsRequestID += 1
        let requestID = lyricsRequestID
        await runBusy {
            pendingLyricsTrackID = track.id
            defer {
                if pendingLyricsTrackID == track.id {
                    pendingLyricsTrackID = nil
                }
            }
            lyricsStatus = "Loading lyrics..."
            if let cached = cache.lyrics(for: track.id) {
                guard requestID == lyricsRequestID else { return }
                applyLyrics(cached, for: track.id)
            } else {
                let fetchedLyrics = try await lyricsProvider.lyrics(for: track)
                cache.storeLyrics(fetchedLyrics, for: track.id)
                guard requestID == lyricsRequestID else { return }
                applyLyrics(fetchedLyrics, for: track.id)
            }
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
            AppLog.event("token refresh joined existing task")
            return try await tokenRefreshTask.value
        }

        AppLog.event("token refresh started")
        let generation = sessionGeneration
        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else {
                throw SpotifyError.authFailed("App state is unavailable.")
            }
            defer { self.tokenRefreshTask = nil }

            let refreshedConfig = try await self.authService.refresh(config: self.config)
            guard generation == self.sessionGeneration else {
                throw CancellationError()
            }
            self.config = refreshedConfig
            try self.configStore.save(refreshedConfig)
            guard let token = refreshedConfig.accessToken else {
                throw SpotifyError.authFailed("Spotify access token is missing.")
            }
            AppLog.event("token refresh finished", metadata: ["expiresAt": self.config.expiresAt?.timeIntervalSince1970])
            return token
        }

        tokenRefreshTask = task
        return try await task.value
    }

    private func refreshNowPlayingWithRetry(intentID: Int) async throws {
        let maxAttempts = 6
        for attempt in 0..<maxAttempts {
            if !playbackTimeline.isCurrent(intentID: intentID) {
                return
            }

            let result = try await refreshNowPlaying()
            if result.application.acknowledges(intentID: intentID)
                || !playbackTimeline.isCurrent(intentID: intentID) {
                return
            }

            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: .milliseconds(400))
            }
        }
        throw SpotifyError.apiFailed("Spotify did not confirm the playback change.")
    }

    private func clearLibraryState() {
        searchRequestID += 1
        playlistOpenRequestID += 1
        playlistPageRequestID += 1
        lyricsRequestID += 1
        trackPlaybackRequestID += 1
        playbackRefreshRequestID += 1
        appliedPlaybackRefreshRequestID = playbackRefreshRequestID
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
        isDeviceBusy = false
        deviceBusyCount = 0
        devices = []
        selectedDeviceID = nil
        pendingDeviceTransferID = nil
        pendingDeviceTransferExpiresAt = nil
        playback = nil
        scrubPreview = nil
        isLyricsPresented = false
        lyrics = nil
        lyricsStatus = ""
        pendingLyricsTrackID = nil
        playbackProjection.clear()
        playbackTimeline.reset()
        cache.clear()
        webPlaybackDeviceID = nil
        webPlaybackNeedsActivation = true
        webPlaybackStatus = "Starting player..."
        webPlaybackReloadID = UUID()
        playbackCommandTail?.cancel()
        playbackCommandTail = nil
        seekCommandTask?.cancel()
        seekCommandTask = nil
        playbackRefreshLoopTask?.cancel()
        playbackRefreshLoopTask = nil
        webPlaybackDisconnectHandler = nil
    }

    private var preferredPlaybackDeviceID: String? {
        if let selectedDeviceID,
           selectedDeviceID == webPlaybackDeviceID || devices.contains(where: { $0.id == selectedDeviceID }) {
            return selectedDeviceID
        }
        return webPlaybackDeviceID
    }

    private var controlsWebPlaybackPlayer: Bool {
        guard let webPlaybackDeviceID else {
            return false
        }
        return preferredPlaybackDeviceID == webPlaybackDeviceID
    }

    private func setPlaybackPlaying(_ shouldPlay: Bool) async throws {
        if controlsWebPlaybackPlayer {
            try await webPlaybackController.perform(shouldPlay ? .resume : .pause)
        } else if shouldPlay {
            try await apiClient.resume(preferredDeviceID: preferredPlaybackDeviceID)
        } else {
            try await apiClient.pause(preferredDeviceID: preferredPlaybackDeviceID)
        }
    }

    private func performSkip(next: Bool) async throws {
        if controlsWebPlaybackPlayer {
            try await webPlaybackController.perform(next ? .next : .previous)
        } else if next {
            try await apiClient.skipNext(preferredDeviceID: preferredPlaybackDeviceID)
        } else {
            try await apiClient.skipPrevious(preferredDeviceID: preferredPlaybackDeviceID)
        }
    }

    private func performSeek(to positionMs: Int) async throws {
        if controlsWebPlaybackPlayer {
            try await webPlaybackController.perform(.seek(positionMs))
        } else {
            try await apiClient.seek(to: positionMs, preferredDeviceID: preferredPlaybackDeviceID)
        }
    }

    private func waitForPlaybackDeviceIfNeeded() async throws {
        if preferredPlaybackDeviceID != nil, !isDeviceBusy {
            return
        }

        guard webPlaybackStatus == "Starting player..." else {
            if isDeviceBusy {
                AppLog.event("waiting for device activation")
            } else {
                throw SpotifyError.noActiveDevice
            }
            for _ in 0..<40 {
                try Task.checkCancellation()
                if preferredPlaybackDeviceID != nil, !isDeviceBusy {
                    AppLog.event("playback device activation finished", metadata: ["deviceID": preferredPlaybackDeviceID])
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw SpotifyError.noActiveDevice
        }

        AppLog.event("waiting for playback device")
        for _ in 0..<40 {
            try Task.checkCancellation()
            if preferredPlaybackDeviceID != nil, !isDeviceBusy {
                AppLog.event("playback device became ready", metadata: ["deviceID": preferredPlaybackDeviceID])
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        AppLog.error("playback device wait timed out")
        throw SpotifyError.noActiveDevice
    }

    private func beginPlaybackIntent(_ kind: PlaybackIntentKind) -> PlaybackIntent {
        let intent = playbackTimeline.beginIntent(
            kind,
            current: playback,
            latestRefreshRequestID: playbackRefreshRequestID
        )
        AppLog.event(
            "playback intent started",
            metadata: [
                "intentID": intent.id,
                "kind": kind.description,
                "trackURI": playback?.item?.uri,
                "progressMs": playback?.estimatedProgressMs
            ]
        )
        return intent
    }

    private func reconcileScrubPreview(with state: SpotifyPlaybackState?) {
        guard scrubPreview?.trackURI == state?.item?.uri else {
            scrubPreview = nil
            return
        }
    }

    private func startProjectedPlayback(_ projectedPlayback: SpotifyPlaybackState, track: SpotifyTrack?) {
        reconcileScrubPreview(with: projectedPlayback)
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

    private func applyPlaybackState(
        _ state: SpotifyPlaybackState?,
        fromRefreshRequest requestID: Int
    ) -> PlaybackApplication {
        let incomingDeviceID = state?.device?.id
        let application = playbackTimeline.applyRESTState(
            state,
            requestID: requestID,
            latestStartedRequestID: playbackRefreshRequestID,
            isCurrentWebDevice: incomingDeviceID != nil && incomingDeviceID == webPlaybackDeviceID,
            replacing: playback
        )

        guard case .applied(let acceptedState, _) = application else {
            AppLog.event(
                "playback state not applied",
                metadata: [
                    "requestID": requestID,
                    "reason": application.description,
                    "incomingTrack": state?.item?.name,
                    "incomingIsPlaying": state?.isPlaying,
                    "incomingProgressMs": state?.progressMs,
                    "currentTrack": playback?.item?.name,
                    "currentIsPlaying": playback?.isPlaying,
                    "currentProgressMs": playback?.progressMs
                ]
            )
            return application
        }

        appliedPlaybackRefreshRequestID = requestID
        if let acceptedState {
            reconcileScrubPreview(with: acceptedState)
            playback = acceptedState
            if let deviceID = acceptedState.device?.id {
                if deviceID == activeDeviceTransferID() {
                    clearDeviceTransferHold()
                }
                selectedDeviceID = activeDeviceTransferID() ?? deviceID
            }
        } else if activeDeviceTransferID() == nil {
            scrubPreview = nil
            playback = nil
            playbackProjection.clear()
            pendingLyricsTrackID = nil
            lyricsRequestID += 1
            lyrics = nil
            lyricsStatus = isLyricsPresented ? "No song playing." : ""
        }
        return application
    }

    private func handlePlaybackUnavailable() {
        AppLog.event("playback unavailable; restarting web playback")
        clearDeviceTransferHold()
        selectedDeviceID = nil
        clearPlaybackState()
        restartWebPlayback()
    }

    private func clearPlaybackState() {
        playback = nil
        scrubPreview = nil
        playbackProjection.clear()
        playbackTimeline.clearPlaybackState()
        pendingLyricsTrackID = nil
        lyricsRequestID += 1
        lyrics = nil
        lyricsStatus = isLyricsPresented ? "No song playing." : ""
    }

    private func restartWebPlayback() {
        AppLog.event("web playback restart requested")
        webPlaybackDisconnectHandler?()
        webPlaybackDeviceID = nil
        lastWebPlaybackReadyAt = nil
        webPlaybackNeedsActivation = true
        webPlaybackStatus = "Starting player..."
        webPlaybackReloadID = UUID()
        webPlaybackController.attach(store: self, reloadID: webPlaybackReloadID)
    }

    private func transferPlaybackToWebPlayerWithRetry(deviceID: String) async throws {
        let maxAttempts = 5
        for attempt in 0..<maxAttempts {
            do {
                try await apiClient.transferPlayback(to: deviceID)
                return
            } catch SpotifyError.noActiveDevice where attempt < maxAttempts - 1 {
                AppLog.event(
                    "web playback transfer waiting for Spotify device registration",
                    metadata: ["attempt": attempt + 1, "deviceID": deviceID]
                )
                try await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func holdDeviceTransfer(to device: SpotifyDevice) {
        selectedDeviceID = device.id
        pendingDeviceTransferID = device.id
        pendingDeviceTransferExpiresAt = PlaybackClock.now + 4
        playback?.device = device
    }

    private func activeDeviceTransferID() -> String? {
        if let expiresAt = pendingDeviceTransferExpiresAt, PlaybackClock.now > expiresAt {
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

    private func beginBusy(_ name: String) {
        busyCount += 1
        isBusy = busyCount > 0
        AppLog.event("busy begin", metadata: ["name": name, "busyCount": busyCount])
    }

    private func endBusy(_ name: String) {
        busyCount = max(0, busyCount - 1)
        isBusy = busyCount > 0
        AppLog.event("busy end", metadata: ["name": name, "busyCount": busyCount])
    }

    private func beginDeviceBusy(_ name: String) {
        deviceBusyCount += 1
        isDeviceBusy = deviceBusyCount > 0
        AppLog.event("device busy begin", metadata: ["name": name, "deviceBusyCount": deviceBusyCount])
        beginBusy(name)
    }

    private func endDeviceBusy(_ name: String) {
        deviceBusyCount = max(0, deviceBusyCount - 1)
        isDeviceBusy = deviceBusyCount > 0
        AppLog.event("device busy end", metadata: ["name": name, "deviceBusyCount": deviceBusyCount])
        endBusy(name)
    }

    private func isCurrentTrackPlaybackRequest(_ requestID: Int) -> Bool {
        requestID == trackPlaybackRequestID && !Task.isCancelled
    }

    private func runLatestPlaybackCommand(
        intentID: Int,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousCommand = playbackCommandTail
        previousCommand?.cancel()
        seekCommandTask?.cancel()
        let command = Task { @MainActor [weak self] in
            await previousCommand?.value
            guard let self, !Task.isCancelled,
                  self.playbackTimeline.isCurrent(intentID: intentID) else {
                return
            }
            await self.executePlaybackCommand(intentID: intentID, operation)
        }
        playbackCommandTail = command
    }

    private func runLatestSeekCommand(
        intentID: Int,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousCommand = playbackCommandTail
        seekCommandTask?.cancel()
        let command = Task { @MainActor [weak self] in
            await previousCommand?.value
            guard let self, !Task.isCancelled,
                  self.playbackTimeline.isCurrent(intentID: intentID) else {
                return
            }
            await self.executePlaybackCommand(intentID: intentID, operation)
        }
        seekCommandTask = command
        playbackCommandTail = command
    }

    private func runPlaybackCommand(
        intentID: Int? = nil,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previousCommand = playbackCommandTail
        let command = Task { @MainActor [weak self] in
            await previousCommand?.value
            guard let self, !Task.isCancelled else {
                return
            }
            await self.executePlaybackCommand(intentID: intentID, operation)
        }
        playbackCommandTail = command
    }

    private func executePlaybackCommand(
        intentID: Int?,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async {
        beginBusy("playback command")
        defer { endBusy("playback command") }

        do {
            try await operation()
        } catch is CancellationError {
            AppLog.event("playback command cancelled", metadata: ["intentID": intentID])
        } catch SpotifyError.noActiveDevice {
            if let intentID {
                await recoverFromFailedIntent(intentID)
            }
            handlePlaybackUnavailable()
            errorMessage = SpotifyError.noActiveDevice.localizedDescription
        } catch {
            if let intentID {
                await recoverFromFailedIntent(intentID)
            }
            surface(error)
        }
    }

    private func recoverFromFailedIntent(_ intentID: Int) async {
        guard playbackTimeline.isCurrent(intentID: intentID) else {
            return
        }
        playback = playbackTimeline.failIntent(intentID)
        AppLog.event("playback intent rolled back", metadata: ["intentID": intentID])
        _ = try? await refreshNowPlaying()
    }

    private func runBusy(_ name: String = "busy operation", _ operation: () async throws -> Void) async {
        beginBusy(name)
        defer { endBusy(name) }
        do {
            try await operation()
        } catch {
            AppLog.error("\(name) failed", error)
            surface(error)
        }
    }

    private func runDeviceBusy(_ name: String = "device operation", _ operation: () async throws -> Void) async {
        beginDeviceBusy(name)
        defer { endDeviceBusy(name) }
        do {
            try await operation()
        } catch {
            AppLog.error("\(name) failed", error)
            surface(error)
        }
    }

    private func surface(_ error: Error) {
        errorMessage = error.localizedDescription
        if let spotifyError = error as? SpotifyError, spotifyError.isNetworkFailure {
            webPlaybackStatus = error.localizedDescription
        }
    }
}

private struct PlaybackRefreshResult {
    let state: SpotifyPlaybackState?
    let application: PlaybackApplication
}

private extension PlaybackApplication {
    var description: String {
        switch self {
        case .applied(_, let intentID):
            if let intentID {
                return "applied; acknowledged intent \(intentID)"
            }
            return "applied"
        case .rejected(let reason):
            return "rejected: \(reason)"
        case .discarded(let reason):
            return "discarded: \(reason)"
        }
    }
}

private extension PlaybackIntentKind {
    var description: String {
        switch self {
        case .playTrack:
            return "play track"
        case .setPlaying(let isPlaying, _):
            return isPlaying ? "resume" : "pause"
        case .seek(_, let positionMs, _):
            return "seek to \(positionMs)ms"
        case .skip:
            return "skip"
        }
    }
}
