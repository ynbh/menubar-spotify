import SwiftUI

struct AuthView: View {
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

            if !store.errorMessage.isEmpty {
                Text(store.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .padding(28)
    }
}
