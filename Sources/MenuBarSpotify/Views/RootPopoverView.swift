import SwiftUI

struct RootPopoverView: View {
    @Bindable var store: SpotifyStore
    @State private var selectedTab: PopoverTab = .search

    var body: some View {
        VStack(spacing: 0) {
            if store.isSignedIn {
                WebPlaybackHostView(store: store)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .id(store.webPlaybackReloadID)

                AccountBarView(store: store)

                NowPlayingView(store: store)
                    .padding(16)

                Picker("", selection: $selectedTab) {
                    ForEach(PopoverTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Group {
                    switch selectedTab {
                    case .search:
                        SearchTabView(store: store)
                    case .playlists:
                        PlaylistsTabView(store: store)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AuthView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if store.isSignedIn, store.isLyricsPresented {
                LyricsSheetView(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.isLyricsPresented)
        .background(.clear)
        .task {
            while !Task.isCancelled {
                if store.isSignedIn {
                    await store.refreshNowPlayingQuietly()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private enum PopoverTab: String, CaseIterable, Identifiable {
    case search
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .playlists: "Playlists"
        }
    }
}
