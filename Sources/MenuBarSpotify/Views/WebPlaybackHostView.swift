import SwiftUI
import WebKit

struct WebPlaybackHostView: NSViewRepresentable {
    private static let messageHandlerName = "spotifyPlayer"
    private static let playerBaseURL = URL(string: "https://localhost")!

    let store: SpotifyStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: Self.messageHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.loadPlayer()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: SpotifyStore
        weak var webView: WKWebView?

        init(store: SpotifyStore) {
            self.store = store
        }

        func loadPlayer() {
            Task { @MainActor in
                guard let token = await store.accessTokenForWebPlayback() else { return }
                webView?.loadHTMLString(playerHTML(accessToken: token), baseURL: WebPlaybackHostView.playerBaseURL)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == WebPlaybackHostView.messageHandlerName,
                  let payload = message.body as? [String: Any],
                  let event = payload["event"] as? String else {
                return
            }

            Task { @MainActor in
                switch event {
                case "ready":
                    if let deviceID = payload["device_id"] as? String {
                        await store.webPlaybackReady(deviceID: deviceID)
                    }
                case "not_ready":
                    store.webPlaybackFailed("MenuBar player went offline.")
                case "error":
                    store.webPlaybackFailed(payload["message"] as? String ?? "Web Playback failed.")
                default:
                    break
                }
            }
        }

        private func playerHTML(accessToken: String) -> String {
            let escapedToken = accessToken
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")

            return """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <style>
                html, body { margin: 0; width: 100%; height: 100%; background: #111; }
              </style>
            </head>
            <body>
              <script src="https://sdk.scdn.co/spotify-player.js"></script>
              <script>
                const accessToken = '\(escapedToken)';
                const post = (payload) => window.webkit.messageHandlers.spotifyPlayer.postMessage(payload);

                window.onSpotifyWebPlaybackSDKReady = () => {
                  const player = new Spotify.Player({
                    name: 'MenuBar Spotify',
                    volume: 0.8,
                    getOAuthToken: callback => callback(accessToken)
                  });

                  window.spotifyPlayer = player;

                  player.addListener('ready', ({ device_id }) => {
                    post({ event: 'ready', device_id });
                  });

                  player.addListener('not_ready', ({ device_id }) => {
                    post({ event: 'not_ready', device_id });
                  });

                  player.addListener('initialization_error', ({ message }) => {
                    post({ event: 'error', message });
                  });

                  player.addListener('authentication_error', ({ message }) => {
                    post({ event: 'error', message });
                  });

                  player.addListener('account_error', ({ message }) => {
                    post({ event: 'error', message });
                  });

                  player.addListener('playback_error', ({ message }) => {
                    post({ event: 'error', message });
                  });

                  player.connect().then(success => {
                    if (!success) post({ event: 'error', message: 'Could not connect Web Playback SDK.' });
                  });
                };
              </script>
            </body>
            </html>
            """
        }
    }
}
