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
    var scrubPreview: PlaybackScrubPreview?
    var isLyricsPresented = false
    var lyrics: LyricsResult?
    var lyricsStatus = ""
    var pendingLyricsTrackID: String?
    var playbackProjection = PlaybackProjection()
    var playbackTimeline = PlaybackTimeline()
    var playlistTracksNextPath: String?
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
    var playbackCommandTail: Task<Void, Never>?
    var seekCommandTask: Task<Void, Never>?
    var playbackRefreshLoopTask: Task<Void, Never>?
    var webPlaybackDisconnectHandler: (() -> Void)?
    var lastWebPlaybackReadyAt: TimeInterval?
    var pendingDeviceTransferID: String?
    var pendingDeviceTransferExpiresAt: TimeInterval?
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap = false
    private var sessionGeneration = 0
    var playbackRefreshRequestID = 0
    var appliedPlaybackRefreshRequestID = 0
    var searchRequestID = 0
    var playlistOpenRequestID = 0
    var playlistPageRequestID = 0
    var lyricsRequestID = 0
    var trackPlaybackRequestID = 0

    private let configStore = ConfigStore.discover()
    private let authService = SpotifyAuthService()
    let lyricsProvider = LRCLIBLyricsProvider()
    var cache = SpotifyCache()
    @ObservationIgnored lazy var webPlaybackController = WebPlaybackController()

    var apiClient: SpotifyAPIClient {
        SpotifyAPIClient { [weak self] in
            guard let self else { throw SpotifyError.authFailed("App state is unavailable.") }
            return try await self.validAccessToken()
        }
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


    func validAccessToken() async throws -> String {
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


    func beginBusy(_ name: String) {
        busyCount += 1
        isBusy = busyCount > 0
        AppLog.event("busy begin", metadata: ["name": name, "busyCount": busyCount])
    }

    func endBusy(_ name: String) {
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


    func runBusy(_ name: String = "busy operation", _ operation: () async throws -> Void) async {
        beginBusy(name)
        defer { endBusy(name) }
        do {
            try await operation()
        } catch {
            AppLog.error("\(name) failed", error)
            surface(error)
        }
    }

    func runDeviceBusy(_ name: String = "device operation", _ operation: () async throws -> Void) async {
        beginDeviceBusy(name)
        defer { endDeviceBusy(name) }
        do {
            try await operation()
        } catch {
            AppLog.error("\(name) failed", error)
            surface(error)
        }
    }

    func surface(_ error: Error) {
        errorMessage = error.localizedDescription
        if let spotifyError = error as? SpotifyError, spotifyError.isNetworkFailure {
            webPlaybackStatus = error.localizedDescription
        }
    }
}
