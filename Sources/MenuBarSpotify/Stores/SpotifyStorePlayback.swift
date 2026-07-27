import Foundation

extension SpotifyStore {
    @discardableResult
    func refreshNowPlaying() async throws -> PlaybackRefreshResult {
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


    func startPlaybackRefreshLoop() {
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


    func refreshNowPlayingWithRetry(intentID: Int) async throws {
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

    func reconcileScrubPreview(with state: SpotifyPlaybackState?) {
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

}

struct PlaybackRefreshResult {
    let state: SpotifyPlaybackState?
    let application: PlaybackApplication
}

extension PlaybackApplication {
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
