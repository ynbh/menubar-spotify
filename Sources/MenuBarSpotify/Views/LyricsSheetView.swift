import SwiftUI

struct LyricsSheetView: View {
    let store: SpotifyStore

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 10)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lyrics")
                        .font(.headline)
                    Text(store.playback?.item?.name ?? "Current song")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    store.isLyricsPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Lyrics")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 12) {
                    if let lyrics = currentLyrics, !lyrics.syncedLines.isEmpty {
                        ForEach(lyrics.syncedLines) { line in
                            Text(line.text)
                                .font(.title3.weight(line.id == activeLineID ? .semibold : .regular))
                                .foregroundStyle(line.id == activeLineID ? Color.green : Color.primary.opacity(0.72))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    } else if let plainLyrics = currentLyrics?.plainLyrics, !plainLyrics.isEmpty {
                        Text(plainLyrics)
                            .font(.title3)
                            .foregroundStyle(.primary.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else if store.lyricsStatus == "Loading lyrics..." {
                        LyricsSkeletonView()
                    } else {
                        Text(store.lyricsStatus.isEmpty ? "Lyrics unavailable for this song." : store.lyricsStatus)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
                    .onChange(of: activeLineID) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .menuBarGlass(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        .shadow(radius: 18, y: -8)
        .task(id: store.playback?.item?.id) {
            await store.loadLyricsForCurrentTrack()
        }
    }

    private var currentLyrics: LyricsResult? {
        guard store.lyrics?.trackID == store.playback?.item?.id else {
            return nil
        }
        return store.lyrics
    }

    private var activeLineID: UUID? {
        _ = store.now
        guard let lines = currentLyrics?.syncedLines, !lines.isEmpty else {
            return nil
        }

        let currentTime = TimeInterval(store.playback?.estimatedProgressMs ?? 0) / 1000
        return lines.last(where: { $0.time <= currentTime })?.id ?? lines.first?.id
    }
}

private struct LyricsSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<7, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5)
                    .fill(.secondary.opacity(0.18))
                    .frame(width: width(for: index), height: 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
    }

    private func width(for index: Int) -> CGFloat {
        [250, 310, 220, 285, 190, 330, 260][index]
    }
}
