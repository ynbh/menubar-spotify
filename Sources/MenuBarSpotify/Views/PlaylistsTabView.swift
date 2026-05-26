import SwiftUI

struct PlaylistsTabView: View {
    let store: SpotifyStore

    var body: some View {
        VStack(spacing: 0) {
            if let playlist = store.selectedPlaylist {
                PlaylistDetailView(store: store, playlist: playlist)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.playlists) { playlist in
                            PlaylistRow(playlist: playlist) {
                                Task { await store.openPlaylist(playlist) }
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
                    store.selectedPlaylist = nil
                    store.playlistTracks = []
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
                    ForEach(store.playlistTracks) { track in
                        TrackRow(track: track) {
                            Task { await store.playPlaylistTrack(track) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
    }
}
