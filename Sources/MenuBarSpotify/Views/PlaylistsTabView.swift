import SwiftUI

struct PlaylistsTabView: View {
    let store: SpotifyStore
    @State private var playlistListOffset: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            if let playlist = store.selectedPlaylist {
                PlaylistDetailView(store: store, playlist: playlist)
            } else {
                PreservingScrollView(offset: $playlistListOffset) {
                    VStack(spacing: 2) {
                        if store.isLoadingPlaylists, store.playlists.isEmpty {
                            ForEach(0..<8, id: \.self) { _ in
                                PlaylistRowSkeleton()
                            }
                        } else {
                            ForEach(store.playlists) { playlist in
                                PlaylistRow(playlist: playlist) {
                                    Task { await store.openPlaylist(playlist) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }
}

private struct PlaylistDetailView: View {
    let store: SpotifyStore
    let playlist: SpotifyPlaylist

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    store.closePlaylist()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 2) {
                    if store.isLoadingPlaylistTracks, store.playlistTracks.isEmpty {
                        ForEach(0..<8, id: \.self) { _ in
                            TrackRowSkeleton()
                        }
                    } else {
                        ForEach(store.playlistTracks) { track in
                            TrackRow(track: track) {
                                Task { await store.playPlaylistTrack(track) }
                            } addToQueue: {
                                Task { await store.addToQueue(track) }
                            }
                        }
                    }

                    if store.playlistTracksHasMore {
                        Button {
                            Task { await store.loadMorePlaylistTracks() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoadingMorePlaylistTracks {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(store.isLoadingMorePlaylistTracks ? "Loading more..." : "Load more songs")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(store.isLoadingMorePlaylistTracks)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }
}
