import XCTest
@testable import MenuBarSpotify

final class PlaybackTimelineTests: XCTestCase {
    func testPauseMaterializesProjectedPosition() {
        var state = playback(progressMs: 10_000, isPlaying: true, uptime: 100)

        state.setPlaying(false, at: 104)

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.progressMs, 14_000)
        XCTAssertEqual(state.estimatedProgressMs(at: 110), 14_000)
    }

    func testProjectionDoesNotMoveBackwardWhenMonotonicSampleIsOlder() {
        let state = playback(progressMs: 10_000, isPlaying: true, uptime: 100)

        XCTAssertEqual(state.estimatedProgressMs(at: 99), 10_000)
    }

    func testStaleSeekSnapshotDoesNotAcknowledgeIntent() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 100)
        let intent = timeline.beginIntent(
            .seek(trackURI: current.item!.uri, positionMs: 50_000, durationMs: 180_000),
            current: current,
            latestRefreshRequestID: 3,
            nowUptime: 100,
            nowUnixMs: 100_000
        )
        let stale = playback(
            progressMs: 11_000,
            isPlaying: true,
            timestampMs: 100_100,
            uptime: 101
        )

        let result = timeline.applyRESTState(
            stale,
            requestID: 4,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 101
        )

        assertRejected(result)
        XCTAssertTrue(timeline.isCurrent(intentID: intent.id))
    }

    func testMatchingSeekSnapshotAcknowledgesIntent() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 100)
        let intent = timeline.beginIntent(
            .seek(trackURI: current.item!.uri, positionMs: 50_000, durationMs: 180_000),
            current: current,
            latestRefreshRequestID: 3,
            nowUptime: 100,
            nowUnixMs: 100_000
        )
        let optimistic = playback(progressMs: 50_000, isPlaying: true, uptime: 100)
        let confirmed = playback(
            progressMs: 50_500,
            isPlaying: true,
            timestampMs: 100_200,
            uptime: 101
        )

        let result = timeline.applyRESTState(
            confirmed,
            requestID: 4,
            isCurrentWebDevice: false,
            replacing: optimistic,
            nowUptime: 101
        )

        XCTAssertTrue(result.acknowledges(intentID: intent.id))
        XCTAssertFalse(timeline.isCurrent(intentID: intent.id))
    }

    func testSeekConfirmationDoesNotFlashBehindOptimisticPosition() {
        var timeline = PlaybackTimeline()
        let beforeSeek = playback(progressMs: 10_000, isPlaying: true, uptime: 100)
        let intent = timeline.beginIntent(
            .seek(trackURI: beforeSeek.item!.uri, positionMs: 50_000, durationMs: 180_000),
            current: beforeSeek,
            latestRefreshRequestID: 3,
            nowUptime: 100,
            nowUnixMs: 100_000
        )
        let optimistic = playback(progressMs: 50_000, isPlaying: true, uptime: 100)
        let laggingConfirmation = playback(
            progressMs: 49_400,
            isPlaying: true,
            timestampMs: 100_200,
            uptime: 100.2
        )

        let result = timeline.applyRESTState(
            laggingConfirmation,
            requestID: 4,
            isCurrentWebDevice: false,
            replacing: optimistic,
            nowUptime: 100.2
        )

        XCTAssertTrue(result.acknowledges(intentID: intent.id))
        guard case .applied(let state, _) = result else {
            return XCTFail("Expected seek confirmation to apply")
        }
        XCTAssertEqual(state?.progressMs, 50_200)
    }

    func testWebSeekConfirmationDoesNotFlashBehindOptimisticPosition() {
        var timeline = PlaybackTimeline()
        timeline.startWebGeneration(1)
        let beforeSeek = playback(progressMs: 20_000, isPlaying: true, uptime: 50)
        let intent = timeline.beginIntent(
            .seek(trackURI: beforeSeek.item!.uri, positionMs: 80_000, durationMs: 180_000),
            current: beforeSeek,
            latestRefreshRequestID: 1,
            nowUptime: 50,
            nowUnixMs: 900_000
        )
        let optimistic = playback(progressMs: 80_000, isPlaying: true, uptime: 50)
        let laggingConfirmation = playback(
            progressMs: 79_200,
            isPlaying: true,
            timestampMs: 900_150,
            uptime: 50.1
        )

        let result = timeline.applyWebState(
            laggingConfirmation,
            generation: 1,
            sequence: 1,
            eventTimestampMs: 900_150,
            replacing: optimistic,
            nowUptime: 50.1
        )

        XCTAssertTrue(result.acknowledges(intentID: intent.id))
        guard case .applied(let state, _) = result else {
            return XCTFail("Expected web seek confirmation to apply")
        }
        XCTAssertEqual(state?.progressMs, 80_100)
    }

    func testStaleRESTAfterWebSeekAckDoesNotFlashToPreSeekPosition() {
        var timeline = PlaybackTimeline()
        timeline.startWebGeneration(1)
        let beforeSeek = playback(progressMs: 149_245, isPlaying: true, uptime: 100)
        _ = timeline.beginIntent(
            .seek(trackURI: beforeSeek.item!.uri, positionMs: 72_830, durationMs: 180_000),
            current: beforeSeek,
            latestRefreshRequestID: 10,
            nowUptime: 100,
            nowUnixMs: 1_000_000
        )
        let optimistic = playback(progressMs: 72_830, isPlaying: true, uptime: 100)
        let webAck = playback(
            progressMs: 72_850,
            isPlaying: true,
            timestampMs: 1_000_080,
            uptime: 100.08
        )

        let webResult = timeline.applyWebState(
            webAck,
            generation: 1,
            sequence: 1,
            eventTimestampMs: 1_000_080,
            replacing: optimistic,
            nowUptime: 100.08
        )
        guard case .applied(let webState, _) = webResult else {
            return XCTFail("Expected web seek ack to apply")
        }

        let staleREST = playback(
            progressMs: 149_155,
            isPlaying: true,
            timestampMs: 1_000_100,
            uptime: 100.16
        )
        let restResult = timeline.applyRESTState(
            staleREST,
            requestID: 11,
            isCurrentWebDevice: true,
            replacing: webState,
            nowUptime: 100.16
        )

        guard case .applied(let state, _) = restResult else {
            return XCTFail("Expected REST snapshot to apply with clamped progress")
        }
        XCTAssertEqual(state?.progressMs, webState?.estimatedProgressMs(at: 100.16))
    }

    func testLatestSeekIntentSupersedesEarlierSeek() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 100)
        let first = timeline.beginIntent(
            .seek(trackURI: current.item!.uri, positionMs: 20_000, durationMs: 180_000),
            current: current,
            latestRefreshRequestID: 5,
            nowUptime: 100,
            nowUnixMs: 100_000
        )
        let second = timeline.beginIntent(
            .seek(trackURI: current.item!.uri, positionMs: 80_000, durationMs: 180_000),
            current: current,
            latestRefreshRequestID: 5,
            nowUptime: 100.1,
            nowUnixMs: 100_100
        )

        let obsolete = playback(
            progressMs: 20_000,
            isPlaying: true,
            timestampMs: 100_200,
            uptime: 100.2
        )
        assertRejected(
            timeline.applyRESTState(
                obsolete,
                requestID: 6,
                isCurrentWebDevice: false,
                replacing: current,
                nowUptime: 100.2
            )
        )
        XCTAssertFalse(timeline.isCurrent(intentID: first.id))
        XCTAssertTrue(timeline.isCurrent(intentID: second.id))

        let latest = playback(
            progressMs: 80_200,
            isPlaying: true,
            timestampMs: 100_300,
            uptime: 100.3
        )
        let result = timeline.applyRESTState(
            latest,
            requestID: 7,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 100.3
        )
        XCTAssertTrue(result.acknowledges(intentID: second.id))
    }

    func testRefreshStartedBeforeIntentIsRejected() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 20_000, isPlaying: true, uptime: 50)
        let intent = timeline.beginIntent(
            .setPlaying(isPlaying: false, trackURI: current.item!.uri),
            current: current,
            latestRefreshRequestID: 10,
            nowUptime: 50,
            nowUnixMs: 200_000
        )
        let paused = playback(
            progressMs: 20_000,
            isPlaying: false,
            timestampMs: 200_100,
            uptime: 50.1
        )

        let result = timeline.applyRESTState(
            paused,
            requestID: 10,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 50.1
        )

        assertRejected(result)
        XCTAssertTrue(timeline.isCurrent(intentID: intent.id))
    }

    func testSkipAcceptsActualNewTrackWithoutPredictingIt() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 40_000, isPlaying: true, uptime: 10)
        let intent = timeline.beginIntent(
            .skip(fromTrackURI: current.item!.uri),
            current: current,
            latestRefreshRequestID: 2,
            nowUptime: 10,
            nowUnixMs: 300_000
        )
        let next = playback(
            track: track(id: "next", uri: "spotify:track:next"),
            progressMs: 500,
            isPlaying: true,
            timestampMs: 300_100,
            uptime: 10.1
        )

        let result = timeline.applyRESTState(
            next,
            requestID: 3,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 10.1
        )

        XCTAssertTrue(result.acknowledges(intentID: intent.id))
        guard case .applied(let state, _) = result else {
            return XCTFail("Expected the new track to be applied")
        }
        XCTAssertEqual(state?.item?.uri, "spotify:track:next")
    }

    func testSeekAtTrackEndAllowsNaturalTransition() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 175_000, isPlaying: true, uptime: 20)
        let intent = timeline.beginIntent(
            .seek(trackURI: current.item!.uri, positionMs: 180_000, durationMs: 180_000),
            current: current,
            latestRefreshRequestID: 1,
            nowUptime: 20,
            nowUnixMs: 400_000
        )
        let next = playback(
            track: track(id: "next", uri: "spotify:track:next"),
            progressMs: 100,
            isPlaying: true,
            timestampMs: 400_100,
            uptime: 20.1
        )

        let result = timeline.applyRESTState(
            next,
            requestID: 2,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 20.1
        )

        XCTAssertTrue(result.acknowledges(intentID: intent.id))
    }

    func testOldWebGenerationCannotMutatePlayback() {
        var timeline = PlaybackTimeline()
        timeline.startWebGeneration(2)
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 10)

        let result = timeline.applyWebState(
            current,
            generation: 1,
            sequence: 1,
            eventTimestampMs: 500_000,
            replacing: current,
            nowUptime: 10
        )

        assertDiscarded(result)
    }

    func testRESTSnapshotOlderThanWebEventIsDiscarded() {
        var timeline = PlaybackTimeline()
        timeline.startWebGeneration(1)
        XCTAssertTrue(
            timeline.observeWebEvent(
                generation: 1,
                sequence: 1,
                eventTimestampMs: 600_000
            )
        )
        let current = playback(progressMs: 30_000, isPlaying: true, uptime: 10)
        let olderREST = playback(
            progressMs: 29_000,
            isPlaying: true,
            timestampMs: 598_000,
            uptime: 10
        )

        let result = timeline.applyRESTState(
            olderREST,
            requestID: 1,
            isCurrentWebDevice: true,
            replacing: current,
            nowUptime: 10
        )

        assertDiscarded(result)
    }

    func testSmallRESTRegressionIsClampedWithoutAnIntent() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 100)
        let incoming = playback(
            progressMs: 10_200,
            isPlaying: true,
            timestampMs: 700_000,
            uptime: 101
        )

        let result = timeline.applyRESTState(
            incoming,
            requestID: 1,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 101
        )

        guard case .applied(let state, _) = result else {
            return XCTFail("Expected snapshot to apply")
        }
        XCTAssertEqual(state?.progressMs, 11_000)
    }

    func testOlderRefreshCannotApplyAfterNewerRefreshStarts() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 10_000, isPlaying: true, uptime: 10)
        let incoming = playback(
            progressMs: 11_000,
            isPlaying: true,
            timestampMs: 750_000,
            uptime: 11
        )

        let result = timeline.applyRESTState(
            incoming,
            requestID: 4,
            latestStartedRequestID: 5,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 11
        )

        assertDiscarded(result)
    }

    func testWebTrackTransitionAcknowledgesPendingSkip() {
        var timeline = PlaybackTimeline()
        timeline.startWebGeneration(3)
        let current = playback(progressMs: 50_000, isPlaying: true, uptime: 20)
        let intent = timeline.beginIntent(
            .skip(fromTrackURI: current.item!.uri),
            current: current,
            latestRefreshRequestID: 2,
            nowUptime: 20,
            nowUnixMs: 760_000
        )

        let acknowledgedIntentID = timeline.observeWebTrackTransition(
            generation: 3,
            sequence: 1,
            trackURI: "spotify:track:next",
            eventTimestampMs: 760_100
        )

        XCTAssertEqual(acknowledgedIntentID, intent.id)
        XCTAssertFalse(timeline.isCurrent(intentID: intent.id))
    }

    func testSameTrackRestartDoesNotAcceptOldHighProgress() {
        var timeline = PlaybackTimeline()
        let current = playback(progressMs: 90_000, isPlaying: true, uptime: 100)
        let intent = timeline.beginIntent(
            .playTrack(trackURI: current.item!.uri),
            current: current,
            latestRefreshRequestID: 1,
            nowUptime: 100,
            nowUnixMs: 800_000
        )
        let oldOccurrence = playback(
            progressMs: 91_000,
            isPlaying: true,
            timestampMs: 800_100,
            uptime: 100.1
        )

        let result = timeline.applyRESTState(
            oldOccurrence,
            requestID: 2,
            isCurrentWebDevice: false,
            replacing: current,
            nowUptime: 100.1
        )

        assertRejected(result)
        XCTAssertTrue(timeline.isCurrent(intentID: intent.id))
    }

    private func playback(
        track: SpotifyTrack? = nil,
        progressMs: Int,
        isPlaying: Bool,
        timestampMs: Int? = nil,
        uptime: TimeInterval
    ) -> SpotifyPlaybackState {
        var state = SpotifyPlaybackState(
            isPlaying: isPlaying,
            progressMs: progressMs,
            item: track ?? self.track(),
            device: SpotifyDevice(
                id: "device",
                name: "Test Player",
                type: "Computer",
                isActive: true,
                isRestricted: false
            )
        )
        state.sourceTimestampMs = timestampMs
        state.receivedAtUptime = uptime
        return state
    }

    private func track(
        id: String = "track",
        uri: String = "spotify:track:track"
    ) -> SpotifyTrack {
        SpotifyTrack(
            id: id,
            name: "Track \(id)",
            uri: uri,
            durationMs: 180_000,
            artists: [SpotifyArtist(name: "Artist")],
            album: nil
        )
    }

    private func assertRejected(
        _ application: PlaybackApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected = application else {
            return XCTFail("Expected state to be rejected", file: file, line: line)
        }
    }

    private func assertDiscarded(
        _ application: PlaybackApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .discarded = application else {
            return XCTFail("Expected state to be discarded", file: file, line: line)
        }
    }
}
