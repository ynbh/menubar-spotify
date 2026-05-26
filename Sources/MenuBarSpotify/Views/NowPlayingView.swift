import SwiftUI

struct NowPlayingView: View {
    let store: SpotifyStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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

                SeekBar(value: progress) { fraction in
                    Task { await store.seek(to: fraction) }
                }
                .frame(height: 12)

                HStack {
                    Text(elapsedText)
                    Spacer()
                    Text(durationText)
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

    private var progress: Double {
        guard let item = store.playback?.item, let progress = store.playback?.progressMs else {
            return 0
        }
        _ = store.now
        let estimatedProgress = store.playback?.estimatedProgressMs ?? progress
        return min(max(Double(estimatedProgress) / Double(item.durationMs), 0), 1)
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

    private var elapsedText: String {
        _ = store.now
        return timeText(ms: store.playback?.estimatedProgressMs ?? 0)
    }

    private var durationText: String {
        timeText(ms: store.playback?.item?.durationMs ?? 0)
    }

    private func timeText(ms: Int) -> String {
        let seconds = ms / 1000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

private struct SeekBar: View {
    let value: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.22))
                    .frame(height: 8)

                Capsule()
                    .fill(.green)
                    .frame(width: max(6, proxy.size.width * value), height: 8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        seek(gesture.location.x / max(proxy.size.width, 1))
                    }
            )
        }
        .help("Seek")
    }
}
