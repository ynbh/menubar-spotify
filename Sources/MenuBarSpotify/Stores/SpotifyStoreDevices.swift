import Foundation

extension SpotifyStore {
    func registerWebPlayback(disconnect: @escaping () -> Void) {
        webPlaybackDisconnectHandler = disconnect
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

        // Local Web Playback can start without activateElement() (or after a
        // prior gesture). Treat an actual playing state as proof audio works.
        if !paused, webPlaybackNeedsActivation {
            webPlaybackNeedsActivation = false
            AppLog.event("web playback activation inferred from playing state")
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


    var preferredPlaybackDeviceID: String? {
        if let selectedDeviceID,
           selectedDeviceID == webPlaybackDeviceID || devices.contains(where: { $0.id == selectedDeviceID }) {
            return selectedDeviceID
        }
        return webPlaybackDeviceID
    }

    var controlsWebPlaybackPlayer: Bool {
        guard let webPlaybackDeviceID else {
            return false
        }
        return preferredPlaybackDeviceID == webPlaybackDeviceID
    }


    func waitForPlaybackDeviceIfNeeded() async throws {
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


    func restartWebPlayback() {
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

    func holdDeviceTransfer(to device: SpotifyDevice) {
        selectedDeviceID = device.id
        pendingDeviceTransferID = device.id
        pendingDeviceTransferExpiresAt = PlaybackClock.now + 4
        playback?.device = device
    }

    func activeDeviceTransferID() -> String? {
        if let expiresAt = pendingDeviceTransferExpiresAt, PlaybackClock.now > expiresAt {
            clearDeviceTransferHold()
        }
        return pendingDeviceTransferID
    }

    func clearDeviceTransferHold() {
        pendingDeviceTransferID = nil
        pendingDeviceTransferExpiresAt = nil
    }

    func device(for id: String) -> SpotifyDevice? {
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

}
