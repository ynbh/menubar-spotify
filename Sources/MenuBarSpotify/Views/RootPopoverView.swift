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

                StatusBarView(store: store)
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
        .task {
            while !Task.isCancelled {
                store.tickClock()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct AccountBarView: View {
    let store: SpotifyStore

    var body: some View {
        HStack {
            Spacer()

            Button {
                Task { await store.signIn() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .help("Reconnect Spotify")

            Button {
                store.signOut()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .help("Sign Out")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
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

private struct AuthView: View {
    let store: SpotifyStore

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)

            VStack(spacing: 6) {
                Text("MenuBar Spotify")
                    .font(.title2.weight(.semibold))
                Text("Sign in to search songs and play your playlists.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await store.signIn() }
            } label: {
                Label("Sign in with Spotify", systemImage: "person.crop.circle")
                    .frame(width: 190)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .padding(28)
    }
}

private struct StatusBarView: View {
    let store: SpotifyStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: store.playback?.device != nil ? "hifispeaker.fill" : "exclamationmark.circle")
                .foregroundStyle(store.playback?.device != nil ? Color.secondary : Color.orange)

            Text(statusText)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 10) {
                Group {
                    if store.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, height: 14)

                Button {
                    Task {
                        try? await store.refreshNowPlaying()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .frame(width: 44, alignment: .trailing)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .menuBarGlass(RoundedRectangle(cornerRadius: 0))
    }

    private var statusText: String {
        optionalStatus ?? store.statusMessage
    }

    private var optionalStatus: String? {
        if store.webPlaybackDeviceID != nil {
            return store.webPlaybackStatus
        }
        if let device = store.playback?.device {
            return device.name
        }
        if store.statusMessage.isEmpty {
            return store.webPlaybackStatus
        }
        return nil
    }
}
