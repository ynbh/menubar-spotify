import Foundation

struct PlaybackScrubPreview {
    let trackURI: String
    let durationMs: Int
    var positionMs: Int

    var fraction: Double {
        guard durationMs > 0 else {
            return 0
        }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }
}

enum PlaybackIntentKind {
    case playTrack(trackURI: String)
    case setPlaying(isPlaying: Bool, trackURI: String?)
    case seek(trackURI: String, positionMs: Int, durationMs: Int)
    case skip(fromTrackURI: String?)
}

struct PlaybackIntent {
    let id: Int
    let kind: PlaybackIntentKind
    let previousPlayback: SpotifyPlaybackState?
    let startedAtUptime: TimeInterval
    let startedAtUnixMs: Int
    let minimumRefreshRequestID: Int
    let webGeneration: Int
    let minimumWebSequence: Int
}

enum PlaybackApplication {
    case applied(state: SpotifyPlaybackState?, acknowledgedIntentID: Int?)
    case rejected(reason: String)
    case discarded(reason: String)

    var wasApplied: Bool {
        if case .applied = self {
            return true
        }
        return false
    }

    func acknowledges(intentID: Int) -> Bool {
        guard case .applied(_, let acknowledgedIntentID) = self else {
            return false
        }
        return acknowledgedIntentID == intentID
    }
}

struct PlaybackTimeline {
    private(set) var pendingIntent: PlaybackIntent?
    private(set) var webGeneration = 0
    private(set) var latestWebSequence = 0
    private(set) var latestWebEventTimestampMs: Int?

    private var nextIntentID = 0
    private var latestAcceptedRefreshRequestID = 0
    private var latestRESTTimestampMs: Int?
    private var progressGuardTrackURI: String?
    private var progressGuardUntilUptime: TimeInterval = 0

    mutating func beginIntent(
        _ kind: PlaybackIntentKind,
        current: SpotifyPlaybackState?,
        latestRefreshRequestID: Int,
        nowUptime: TimeInterval = PlaybackClock.now,
        nowUnixMs: Int = PlaybackClock.unixMilliseconds
    ) -> PlaybackIntent {
        nextIntentID += 1
        let intent = PlaybackIntent(
            id: nextIntentID,
            kind: kind,
            previousPlayback: current,
            startedAtUptime: nowUptime,
            startedAtUnixMs: nowUnixMs,
            minimumRefreshRequestID: latestRefreshRequestID + 1,
            webGeneration: webGeneration,
            minimumWebSequence: latestWebSequence
        )
        pendingIntent = intent
        if case .seek(let trackURI, _, _) = kind {
            armProgressGuard(trackURI: trackURI, at: nowUptime)
        }
        return intent
    }

    func isCurrent(intentID: Int) -> Bool {
        pendingIntent?.id == intentID
    }

    mutating func failIntent(_ intentID: Int) -> SpotifyPlaybackState? {
        guard pendingIntent?.id == intentID else {
            return nil
        }
        let previousPlayback = pendingIntent?.previousPlayback
        pendingIntent = nil
        clearProgressGuard()
        return previousPlayback
    }

    mutating func clearIntent(_ intentID: Int) {
        guard pendingIntent?.id == intentID else {
            return
        }
        pendingIntent = nil
    }

    mutating func startWebGeneration(_ generation: Int) {
        guard generation >= webGeneration else {
            return
        }
        webGeneration = generation
        latestWebSequence = 0
        latestWebEventTimestampMs = nil
    }

    mutating func observeWebEvent(
        generation: Int,
        sequence: Int,
        eventTimestampMs: Int
    ) -> Bool {
        guard generation == webGeneration, sequence > latestWebSequence else {
            return false
        }
        latestWebSequence = sequence
        latestWebEventTimestampMs = max(latestWebEventTimestampMs ?? eventTimestampMs, eventTimestampMs)
        return true
    }

    mutating func observeWebTrackTransition(
        generation: Int,
        sequence: Int,
        trackURI: String,
        eventTimestampMs: Int
    ) -> Int? {
        guard observeWebEvent(
            generation: generation,
            sequence: sequence,
            eventTimestampMs: eventTimestampMs
        ), let pendingIntent else {
            return nil
        }

        let confirmsIntent: Bool
        switch pendingIntent.kind {
        case .playTrack(let expectedTrackURI):
            confirmsIntent = trackURI == expectedTrackURI
        case .setPlaying(_, let previousTrackURI):
            confirmsIntent = trackURI != previousTrackURI
        case .seek(let previousTrackURI, _, _):
            confirmsIntent = trackURI != previousTrackURI
        case .skip(let previousTrackURI):
            confirmsIntent = trackURI != previousTrackURI
        }

        guard confirmsIntent else {
            return nil
        }
        self.pendingIntent = nil
        return pendingIntent.id
    }

    mutating func applyWebState(
        _ incoming: SpotifyPlaybackState,
        generation: Int,
        sequence: Int,
        eventTimestampMs: Int,
        replacing current: SpotifyPlaybackState?,
        nowUptime: TimeInterval = PlaybackClock.now
    ) -> PlaybackApplication {
        guard observeWebEvent(
            generation: generation,
            sequence: sequence,
            eventTimestampMs: eventTimestampMs
        ) else {
            return .discarded(reason: "stale web player event")
        }

        guard let decision = decisionForPendingIntent(
            incoming,
            sourceIsWebPlayer: true,
            sourceIsFresh: true,
            replacing: current,
            nowUptime: nowUptime
        ) else {
            return .rejected(reason: "web player state does not confirm current intent")
        }

        let normalized = stabilizeSameTrackProgress(
            incoming,
            replacing: current,
            nowUptime: nowUptime,
            clampAbsoluteDelta: false
        )
        if decision.acknowledgesIntent {
            let intentID = pendingIntent?.id
            pendingIntent = nil
            return .applied(state: normalized, acknowledgedIntentID: intentID)
        }
        return .applied(state: normalized, acknowledgedIntentID: nil)
    }

    mutating func applyRESTState(
        _ incoming: SpotifyPlaybackState?,
        requestID: Int,
        latestStartedRequestID: Int? = nil,
        isCurrentWebDevice: Bool,
        replacing current: SpotifyPlaybackState?,
        nowUptime: TimeInterval = PlaybackClock.now
    ) -> PlaybackApplication {
        if let latestStartedRequestID, requestID < latestStartedRequestID {
            return .discarded(reason: "newer refresh request is already in flight")
        }

        guard requestID >= latestAcceptedRefreshRequestID else {
            return .discarded(reason: "older refresh request")
        }

        if let incomingTimestamp = incoming?.sourceTimestampMs,
           let latestRESTTimestampMs,
           incomingTimestamp < latestRESTTimestampMs {
            return .discarded(reason: "older Spotify snapshot timestamp")
        }

        if isCurrentWebDevice,
           let incomingTimestamp = incoming?.sourceTimestampMs,
           let latestWebEventTimestampMs,
           incomingTimestamp + 1_500 < latestWebEventTimestampMs {
            return .discarded(reason: "REST snapshot predates web player event")
        }

        if let pendingIntent, requestID < pendingIntent.minimumRefreshRequestID {
            return .rejected(reason: "refresh started before current intent")
        }

        guard let incoming else {
            guard pendingIntent == nil else {
                return .rejected(reason: "empty playback cannot confirm current intent")
            }
            latestAcceptedRefreshRequestID = requestID
            return .applied(state: nil, acknowledgedIntentID: nil)
        }

        let sourceIsFresh = incoming.sourceTimestampMs.map { timestamp in
            guard let pendingIntent else { return true }
            return timestamp >= pendingIntent.startedAtUnixMs - 1_500
        } ?? true

        guard let decision = decisionForPendingIntent(
            incoming,
            sourceIsWebPlayer: false,
            sourceIsFresh: sourceIsFresh,
            replacing: current,
            nowUptime: nowUptime
        ) else {
            return .rejected(reason: "REST state does not confirm current intent")
        }

        latestAcceptedRefreshRequestID = requestID
        if let timestamp = incoming.sourceTimestampMs {
            latestRESTTimestampMs = max(latestRESTTimestampMs ?? timestamp, timestamp)
        }

        // Local Web Playback already owns low-latency position. Stale REST
        // snapshots often keep a fresh Spotify timestamp with an old
        // progress_ms right after seek — clamp hard while the guard is live or
        // the web player is the active device.
        let clampAbsoluteDelta = isCurrentWebDevice || hasActiveProgressGuard(
            for: incoming.item?.uri,
            at: nowUptime
        )
        let normalized = stabilizeSameTrackProgress(
            incoming,
            replacing: current,
            nowUptime: nowUptime,
            clampAbsoluteDelta: clampAbsoluteDelta
        )
        if decision.acknowledgesIntent {
            let intentID = pendingIntent?.id
            pendingIntent = nil
            return .applied(state: normalized, acknowledgedIntentID: intentID)
        }
        return .applied(state: normalized, acknowledgedIntentID: nil)
    }

    mutating func clearPlaybackState() {
        pendingIntent = nil
        latestAcceptedRefreshRequestID = 0
        latestRESTTimestampMs = nil
        clearProgressGuard()
    }

    mutating func reset() {
        clearPlaybackState()
        nextIntentID = 0
        webGeneration = 0
        latestWebSequence = 0
        latestWebEventTimestampMs = nil
    }

    private func decisionForPendingIntent(
        _ incoming: SpotifyPlaybackState,
        sourceIsWebPlayer: Bool,
        sourceIsFresh: Bool,
        replacing current: SpotifyPlaybackState?,
        nowUptime: TimeInterval
    ) -> PendingIntentDecision? {
        guard let pendingIntent else {
            return PendingIntentDecision(acknowledgesIntent: false)
        }

        if sourceIsWebPlayer {
            guard pendingIntent.webGeneration == webGeneration,
                  latestWebSequence > pendingIntent.minimumWebSequence else {
                return nil
            }
        }

        let incomingURI = incoming.item?.uri
        switch pendingIntent.kind {
        case .playTrack(let trackURI):
            guard incomingURI == trackURI, incoming.isPlaying else {
                return nil
            }
            let elapsedMs = max(0, Int((nowUptime - pendingIntent.startedAtUptime) * 1_000))
            let maximumStartProgress = elapsedMs + 3_000
            guard sourceIsWebPlayer || sourceIsFresh,
                  (incoming.progressMs ?? 0) <= maximumStartProgress else {
                return nil
            }

        case .setPlaying(let expectedIsPlaying, let trackURI):
            if incomingURI != trackURI {
                return PendingIntentDecision(acknowledgesIntent: true)
            }
            guard incoming.isPlaying == expectedIsPlaying else {
                return nil
            }

        case .seek(let trackURI, let positionMs, let durationMs):
            if incomingURI != trackURI {
                return PendingIntentDecision(acknowledgesIntent: true)
            }
            guard let progressMs = incoming.progressMs else {
                return nil
            }
            let elapsedMs = incoming.isPlaying
                ? max(0, Int((nowUptime - pendingIntent.startedAtUptime) * 1_000))
                : 0
            let lowerBound = max(0, positionMs - 1_000)
            let upperBound = min(durationMs, positionMs + elapsedMs + 2_000)
            guard progressMs >= lowerBound, progressMs <= upperBound else {
                return nil
            }

        case .skip(let fromTrackURI):
            if incomingURI != fromTrackURI {
                return PendingIntentDecision(acknowledgesIntent: true)
            }
            guard sourceIsWebPlayer || sourceIsFresh,
                  (incoming.progressMs ?? Int.max) <= 3_000 else {
                return nil
            }
        }

        return PendingIntentDecision(acknowledgesIntent: true)
    }

    /// Keeps the bar from flashing when a snapshot lags or still reports the
    /// pre-seek position after Web Playback already confirmed the seek.
    private mutating func stabilizeSameTrackProgress(
        _ incoming: SpotifyPlaybackState,
        replacing current: SpotifyPlaybackState?,
        nowUptime: TimeInterval,
        clampAbsoluteDelta: Bool
    ) -> SpotifyPlaybackState {
        var normalized = incoming
        normalized.receivedAtUptime = nowUptime

        guard incoming.item?.uri == current?.item?.uri,
              let current else {
            return normalized
        }

        let currentPosition = current.estimatedProgressMs(at: nowUptime)
        let incomingPosition = normalized.estimatedProgressMs(at: nowUptime)
        let delta = currentPosition - incomingPosition
        let guardActive = hasActiveProgressGuard(for: incoming.item?.uri, at: nowUptime)
        let shouldClampAbsolute = clampAbsoluteDelta || guardActive

        if shouldClampAbsolute, abs(delta) > 1_500 {
            normalized.progressMs = currentPosition
            normalized.receivedAtUptime = nowUptime
            return normalized
        }

        if delta > 0, delta <= 1_500 {
            normalized.progressMs = currentPosition
            normalized.receivedAtUptime = nowUptime
        }

        if guardActive, abs(delta) <= 1_500 {
            clearProgressGuard()
        }
        return normalized
    }

    private mutating func armProgressGuard(trackURI: String, at uptime: TimeInterval) {
        progressGuardTrackURI = trackURI
        progressGuardUntilUptime = uptime + 3
    }

    private mutating func clearProgressGuard() {
        progressGuardTrackURI = nil
        progressGuardUntilUptime = 0
    }

    private func hasActiveProgressGuard(for trackURI: String?, at uptime: TimeInterval) -> Bool {
        guard let trackURI,
              progressGuardTrackURI == trackURI,
              uptime < progressGuardUntilUptime else {
            return false
        }
        return true
    }
}

private struct PendingIntentDecision {
    let acknowledgesIntent: Bool
}

enum PlaybackClock {
    static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static var unixMilliseconds: Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}
