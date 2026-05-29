import SwiftUI

struct SettingsView: View {
    let store: SpotifyStore

    var body: some View {
        Form {
            LabeledContent("Config") {
                Text(".config")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Redirect URI") {
                Text(store.config.redirectURI)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Session") {
                    Task { await store.refreshSession() }
                }

                Button("Sign Out") {
                    store.signOut()
                }
                .disabled(!store.isSignedIn)
            }

            if !store.errorMessage.isEmpty {
                Text(store.errorMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
