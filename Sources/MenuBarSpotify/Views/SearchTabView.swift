import SwiftUI

struct SearchTabView: View {
    @Bindable var store: SpotifyStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search songs", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await store.search() }
                    }
                Button {
                    Task { await store.search() }
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .menuBarGlass(RoundedRectangle(cornerRadius: 10), interactive: true)
            .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 2) {
                    if showsRecentTracks {
                        HStack {
                            Text("Recent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }

                    ForEach(displayedTracks) { track in
                        TrackRow(track: track) {
                            Task { await store.playTrack(track) }
                        } addToQueue: {
                            Task { await store.addToQueue(track) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .task {
            if store.recentTracks.isEmpty {
                await store.loadRecentTracks()
            }
        }
    }

    private var showsRecentTracks: Bool {
        store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedTracks: [SpotifyTrack] {
        showsRecentTracks ? store.recentTracks : store.searchResults
    }
}
