import SwiftUI

@main
struct MenuBarSpotifyApp: App {
    @State private var store = SpotifyStore()

    var body: some Scene {
        MenuBarExtra {
            RootPopoverView(store: store)
                .frame(width: 420, height: 540)
                .task {
                    await store.bootstrap()
                }
        } label: {
            Image(systemName: "music.note")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .frame(width: 420)
                .padding()
        }
    }
}
