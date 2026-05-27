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
        context.coordinator.attach(webView: webView, contentController: contentController)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let store: SpotifyStore
        private weak var webView: WKWebView?
        private weak var contentController: WKUserContentController?

        init(store: SpotifyStore) {
            self.store = store
        }

        func attach(webView: WKWebView, contentController: WKUserContentController) {
            self.webView = webView
            self.contentController = contentController
            store.registerWebPlayback { [weak self] in
                self?.disconnectPlayer()
            }
            loadPlayer()
        }

        func teardown() {
            disconnectPlayer()
            contentController?.removeScriptMessageHandler(forName: WebPlaybackHostView.messageHandlerName)
            webView = nil
            contentController = nil
        }

        func disconnectPlayer() {
            webView?.evaluateJavaScript("window.__disconnectSpotifyPlayer?.();", completionHandler: nil)
        }

        func loadPlayer() {
            webView?.loadHTMLString(Self.playerHTML, baseURL: WebPlaybackHostView.playerBaseURL)
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
                case "get_token":
                    guard let requestID = payload["request_id"] as? Int else {
                        return
                    }
                    await deliverAccessToken(requestID: requestID)
                default:
                    break
                }
            }
        }

        private func deliverAccessToken(requestID: Int) async {
            guard let token = await store.accessTokenForWebPlayback(),
                  let tokenJSON = jsonLiteral(for: token) else {
                return
            }
            webView?.evaluateJavaScript("window.__deliverToken(\(requestID), \(tokenJSON));", completionHandler: nil)
        }

        private func jsonLiteral(for string: String) -> String? {
            guard let data = try? JSONEncoder().encode(string) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        private static let playerHTML = """
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
            const post = (payload) => window.webkit.messageHandlers.spotifyPlayer.postMessage(payload);
            const tokenCallbacks = new Map();
            let tokenRequestId = 0;

            window.__deliverToken = (id, token) => {
              const callback = tokenCallbacks.get(id);
              tokenCallbacks.delete(id);
              if (callback) callback(token);
            };

            window.__disconnectSpotifyPlayer = () => {
              if (window.spotifyPlayer) {
                window.spotifyPlayer.disconnect();
                window.spotifyPlayer = null;
              }
            };

            const requestAccessToken = (callback) => {
              const id = ++tokenRequestId;
              tokenCallbacks.set(id, callback);
              post({ event: 'get_token', request_id: id });
            };

            window.onSpotifyWebPlaybackSDKReady = () => {
              const player = new Spotify.Player({
                name: 'MenuBar Spotify',
                volume: 0.8,
                getOAuthToken: requestAccessToken
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
