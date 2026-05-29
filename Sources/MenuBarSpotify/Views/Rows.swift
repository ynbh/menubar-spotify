import SwiftUI

struct TrackRow: View {
    let track: SpotifyTrack
    let play: () -> Void
    let addToQueue: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: play) {
                HStack(spacing: 10) {
                    ArtworkView(url: track.artworkURL, size: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(track.artistLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(track.durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .contentShape(Rectangle())
                .padding(.leading, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button(action: addToQueue) {
                Image(systemName: "text.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add to Queue")
            .padding(.trailing, 6)
        }
        .background(.quaternary.opacity(0.001), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlaylistRow: View {
    let playlist: SpotifyPlaylist
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ArtworkView(url: playlist.artworkURL, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(playlist.tracks.total) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

struct TrackRowSkeleton: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 220, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 145, height: 11)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 4)
                .frame(width: 34, height: 11)
        }
        .foregroundStyle(.secondary.opacity(0.18))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
    }
}

struct PlaylistRowSkeleton: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 210, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 80, height: 11)
            }

            Spacer()
        }
        .foregroundStyle(.secondary.opacity(0.18))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            await loadImage()
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
        }
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }

        if loadedURL == url, image != nil {
            return
        }

        if let cached = ImageMemoryCache.shared.cachedImage(for: url) {
            image = cached
            loadedURL = url
            return
        }

        image = nil
        isLoading = true
        defer { isLoading = false }

        do {
            image = try await ImageMemoryCache.shared.image(for: url)
            loadedURL = url
        } catch {
            image = nil
            loadedURL = nil
        }
    }
}
