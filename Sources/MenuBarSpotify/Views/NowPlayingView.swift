import SwiftUI

struct NowPlayingView: View {
    let store: SpotifyStore
    @State private var dragTrackURI: String?
    @State private var dragWasInvalidated = false
    @State private var isSliderEditing = false

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: store.playback?.isPlaying != true && store.scrubPreview == nil
            )
        ) { _ in
            content(at: PlaybackClock.now)
        }
        .onChange(of: store.playback?.item?.uri) { _, trackURI in
            guard let dragTrackURI, dragTrackURI != trackURI else {
                return
            }
            dragWasInvalidated = true
            store.cancelScrubPreview()
        }
        .onDisappear {
            dragTrackURI = nil
            dragWasInvalidated = false
            isSliderEditing = false
            store.cancelScrubPreview()
        }
    }

    private func content(at uptime: TimeInterval) -> some View {
        let positionMs = store.playbackProgressMs(at: uptime)
        let durationMs = store.playback?.item?.durationMs ?? 0
        let progress = progressFraction(positionMs: positionMs, durationMs: durationMs)

        return HStack(alignment: .top, spacing: 14) {
            ArtworkView(url: store.playback?.item?.artworkURL, size: 88)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.playback?.item?.name ?? "Nothing Playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }

                Slider(
                    value: sliderBinding(displayedProgress: progress),
                    in: 0...1,
                    onEditingChanged: sliderEditingChanged
                )
                .tint(.green)
                .controlSize(.small)
                .disabled(durationMs <= 0)
                .transaction { $0.animation = nil }
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(timeText(ms: positionMs)) of \(timeText(ms: durationMs))")
                .help("Seek")

                HStack {
                    Text(timeText(ms: positionMs))
                    Spacer()
                    Text(timeText(ms: durationMs))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                HStack(spacing: 18) {
                    Button {
                        Task { await store.skipPrevious() }
                    } label: {
                        Image(systemName: "backward.fill")
                    }

                    Button {
                        Task { await store.togglePlayback() }
                    } label: {
                        Image(systemName: store.playback?.isPlaying == true ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }

                    Button {
                        Task { await store.skipNext() }
                    } label: {
                        Image(systemName: "forward.fill")
                    }

                    Button {
                        store.toggleLyrics()
                    } label: {
                        Image(systemName: "text.quote")
                    }
                    .help("Lyrics")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
            .padding(.top, -2)
        }
    }

    private var subtitle: String {
        if let artistLine = store.playback?.item?.artistLine {
            return artistLine
        }
        if let device = store.playback?.device {
            return device.name
        }
        return store.webPlaybackStatus
    }

    private func sliderBinding(displayedProgress: Double) -> Binding<Double> {
        Binding(
            get: { displayedProgress },
            set: { fraction in
                updateScrubPreview(fraction)
                if !isSliderEditing {
                    Task { @MainActor in
                        await Task.yield()
                        guard !isSliderEditing,
                              dragTrackURI != nil,
                              store.scrubPreview != nil else {
                            return
                        }
                        finishScrubbing(fraction)
                    }
                }
            }
        )
    }

    private func sliderEditingChanged(_ editing: Bool) {
        isSliderEditing = editing
        if editing {
            beginScrubbing()
        } else {
            finishScrubbing(store.scrubPreview?.fraction ?? 0)
        }
    }

    private func beginScrubbing() {
        guard let trackURI = store.playback?.item?.uri else {
            return
        }
        dragTrackURI = trackURI
        dragWasInvalidated = false
    }

    private func updateScrubPreview(_ fraction: Double) {
        guard let trackURI = store.playback?.item?.uri else {
            return
        }
        if dragTrackURI == nil {
            beginScrubbing()
        }
        guard dragTrackURI == trackURI, !dragWasInvalidated else {
            return
        }
        store.updateScrubPreview(to: fraction)
    }

    private func finishScrubbing(_ fraction: Double) {
        updateScrubPreview(fraction)
        let shouldCommit = !dragWasInvalidated
            && dragTrackURI != nil
            && dragTrackURI == store.playback?.item?.uri
        dragTrackURI = nil
        dragWasInvalidated = false

        guard shouldCommit else {
            store.cancelScrubPreview()
            return
        }
        store.commitScrubPreview()
    }

    private func progressFraction(positionMs: Int, durationMs: Int) -> Double {
        guard durationMs > 0 else {
            return 0
        }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }

    private func timeText(ms: Int) -> String {
        let seconds = max(0, ms) / 1_000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
