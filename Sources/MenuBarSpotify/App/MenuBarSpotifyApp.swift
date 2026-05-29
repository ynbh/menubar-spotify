import AppKit
import SwiftUI

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SpotifyStore?

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { store?.handleOpenURL($0) }
    }
}

@main
struct MenuBarSpotifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SpotifyStore()

    init() {
        let store = SpotifyStore()
        _store = State(initialValue: store)
        appDelegate.store = store
    }

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
