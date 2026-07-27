import SwiftUI
import WebKit

struct WebPlaybackHostView: NSViewRepresentable {
    let store: SpotifyStore

    func makeNSView(context: Context) -> WKWebView {
        let controller = store.webPlaybackController
        controller.attach(store: store, reloadID: store.webPlaybackReloadID)
        return controller.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        store.webPlaybackController.attach(store: store, reloadID: store.webPlaybackReloadID)
    }
}

@MainActor
final class WebPlaybackController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let messageHandlerName = "spotifyPlayer"
    private static let playerBaseURL = URL(string: "https://localhost")!

    private weak var store: SpotifyStore?
    private var contentController: WKUserContentController!
    private var loadedReloadID: UUID?
    private var currentDeviceID: String?
    private(set) var generation = 0
    private(set) var webView: WKWebView!

    override init() {
        super.init()

        let contentController = WKUserContentController()
        contentController.add(self, name: Self.messageHandlerName)
        self.contentController = contentController

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.focusRingType = .none
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
        AppLog.event("persistent web playback webview created")
    }

    func attach(store: SpotifyStore, reloadID: UUID) {
        self.store = store
        store.registerWebPlayback { [weak self] in
            self?.disconnectPlayer()
        }
        guard loadedReloadID != reloadID else {
            return
        }
        loadedReloadID = reloadID
        loadPlayer()
    }

    func disconnectPlayer() {
        AppLog.event("web playback disconnect requested", metadata: ["generation": generation])
        webView.evaluateJavaScript("window.__disconnectSpotifyPlayer?.();", completionHandler: nil)
    }

    func perform(_ command: WebPlaybackCommand) async throws {
        let script: String
        switch command {
        case .pause:
            script = "return await window.__spotifyCommand('pause');"
        case .resume:
            script = "return await window.__spotifyCommand('resume');"
        case .seek(let positionMs):
            script = "return await window.__spotifyCommand('seek', \(positionMs));"
        case .next:
            script = "return await window.__spotifyCommand('next');"
        case .previous:
            script = "return await window.__spotifyCommand('previous');"
        }

        do {
            _ = try await webView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            AppLog.event(
                "web playback command finished",
                metadata: ["command": command.description, "generation": generation]
            )
        } catch {
            AppLog.error(
                "web playback command failed",
                error,
                metadata: ["command": command.description, "generation": generation]
            )
            throw error
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        AppLog.event("web playback webview navigation finished", metadata: ["generation": generation])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLog.error("web playback webview navigation failed", error, metadata: ["generation": generation])
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        AppLog.error("web playback webview provisional navigation failed", error, metadata: ["generation": generation])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName,
              let payload = message.body as? [String: Any],
              let event = payload["event"] as? String,
              let payloadGeneration = payload["generation"] as? Int,
              payloadGeneration == generation else {
            return
        }

        AppLog.event(
            "web playback script event",
            metadata: ["event": event, "generation": payloadGeneration]
        )
        Task { @MainActor [weak self] in
            guard let self, let store = self.store, payloadGeneration == self.generation else {
                return
            }

            switch event {
            case "ready":
                if let deviceID = payload["device_id"] as? String {
                    self.currentDeviceID = deviceID
                    await store.webPlaybackReady(deviceID: deviceID, generation: payloadGeneration)
                }
            case "not_ready":
                let deviceID = payload["device_id"] as? String
                self.currentDeviceID = nil
                store.webPlaybackWentOffline(deviceID: deviceID)
            case "error":
                store.webPlaybackFailed(payload["message"] as? String ?? "Web Playback failed.")
            case "audio_activated":
                store.webPlaybackAudioActivated()
            case "audio_activation_failed":
                store.webPlaybackAudioActivationFailed(
                    payload["message"] as? String ?? "Could not enable audio."
                )
            case "autoplay_failed":
                store.webPlaybackAutoplayFailed()
            case "player_state":
                guard let sequence = payload["sequence"] as? Int,
                      let paused = payload["paused"] as? Bool,
                      let positionMs = payload["position_ms"] as? Int,
                      let eventTimestampMs = payload["event_timestamp_ms"] as? Int else {
                    return
                }
                let durationMs = payload["duration_ms"] as? Int
                let trackURI = payload["track_uri"] as? String
                store.webPlaybackStateChanged(
                    generation: payloadGeneration,
                    sequence: sequence,
                    paused: paused,
                    positionMs: positionMs,
                    durationMs: durationMs,
                    trackURI: trackURI,
                    eventTimestampMs: eventTimestampMs
                )
                self.logNativeMediaPlaybackState()
            case "get_token":
                guard let requestID = payload["request_id"] as? Int else {
                    return
                }
                await self.deliverAccessToken(
                    requestID: requestID,
                    generation: payloadGeneration
                )
            default:
                break
            }
        }
    }

    private func loadPlayer() {
        generation += 1
        currentDeviceID = nil
        store?.webPlaybackGenerationStarted(generation)
        AppLog.event("web playback html load requested", metadata: ["generation": generation])
        webView.loadHTMLString(Self.playerHTML(generation: generation), baseURL: Self.playerBaseURL)
    }

    private func deliverAccessToken(requestID: Int, generation: Int) async {
        guard generation == self.generation,
              let token = await store?.accessTokenForWebPlayback(),
              let tokenJSON = jsonLiteral(for: token) else {
            AppLog.error(
                "web playback token delivery failed",
                metadata: ["requestID": requestID, "generation": generation]
            )
            return
        }

        do {
            _ = try await webView.evaluateJavaScript(
                "window.__deliverToken(\(generation), \(requestID), \(tokenJSON));"
            )
            AppLog.event(
                "web playback token delivered",
                metadata: ["requestID": requestID, "generation": generation]
            )
        } catch {
            AppLog.error(
                "web playback token javascript failed",
                error,
                metadata: ["requestID": requestID, "generation": generation]
            )
        }
    }

    private func logNativeMediaPlaybackState() {
        let window = webView.window
        webView.requestMediaPlaybackState { state in
            AppLog.event(
                "web playback native media state",
                metadata: [
                    "state": String(describing: state),
                    "hasWindow": window != nil,
                    "windowVisible": window?.isVisible,
                    "windowKey": window?.isKeyWindow
                ]
            )
        }
    }

    private func jsonLiteral(for string: String) -> String? {
        guard let data = try? JSONEncoder().encode(string) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func playerHTML(generation: Int) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              background: transparent;
            }
            #enable-audio {
              position: fixed;
              inset: 0;
              width: 100%;
              height: 100%;
              margin: 0;
              padding: 0;
              border: 0;
              background: transparent;
              color: transparent;
              cursor: pointer;
              outline: none;
              box-shadow: none;
              -webkit-appearance: none;
            }
            #enable-audio:focus { outline: none; box-shadow: none; }
            #enable-audio:disabled { cursor: default; }
          </style>
        </head>
        <body>
          <button id="enable-audio" type="button" aria-label="Enable Audio" disabled></button>
          <script src="https://sdk.scdn.co/spotify-player.js"></script>
          <script>
            const generation = \(generation);
            const post = (payload) => window.webkit.messageHandlers.spotifyPlayer.postMessage({
              ...payload,
              generation
            });
            const enableAudioButton = document.getElementById('enable-audio');
            const tokenCallbacks = new Map();
            let tokenRequestId = 0;
            let playerStateSequence = 0;

            window.__deliverToken = (callbackGeneration, id, token) => {
              if (callbackGeneration !== generation) return;
              const callback = tokenCallbacks.get(id);
              tokenCallbacks.delete(id);
              if (callback) callback(token);
            };

            window.__disconnectSpotifyPlayer = () => {
              tokenCallbacks.clear();
              if (window.spotifyPlayer) {
                window.spotifyPlayer.disconnect();
                window.spotifyPlayer = null;
              }
            };

            window.__spotifyCommand = async (command, value) => {
              const player = window.spotifyPlayer;
              if (!player) throw new Error('Web Playback player is not ready.');
              switch (command) {
                case 'pause': return await player.pause();
                case 'resume': return await player.resume();
                case 'seek': return await player.seek(value);
                case 'next': return await player.nextTrack();
                case 'previous': return await player.previousTrack();
                default: throw new Error(`Unsupported playback command: ${command}`);
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

              enableAudioButton.addEventListener('click', () => {
                enableAudioButton.disabled = true;
                try {
                  Promise.resolve(player.activateElement())
                    .then(() => {
                      enableAudioButton.textContent = 'Enabled';
                      post({ event: 'audio_activated' });
                    })
                    .catch((error) => {
                      enableAudioButton.disabled = false;
                      post({ event: 'audio_activation_failed', message: String(error) });
                    });
                } catch (error) {
                  enableAudioButton.disabled = false;
                  post({ event: 'audio_activation_failed', message: String(error) });
                }
              });

              player.addListener('ready', ({ device_id }) => {
                enableAudioButton.disabled = false;
                post({ event: 'ready', device_id });
              });

              player.addListener('not_ready', ({ device_id }) => {
                post({ event: 'not_ready', device_id });
              });

              player.addListener('initialization_error', ({ message }) => {
                post({ event: 'error', error_type: 'initialization', message });
              });

              player.addListener('authentication_error', ({ message }) => {
                post({ event: 'error', error_type: 'authentication', message });
              });

              player.addListener('account_error', ({ message }) => {
                post({ event: 'error', error_type: 'account', message });
              });

              player.addListener('playback_error', ({ message }) => {
                post({ event: 'error', error_type: 'playback', message });
              });

              player.addListener('autoplay_failed', () => {
                enableAudioButton.disabled = false;
                post({ event: 'autoplay_failed' });
              });

              player.addListener('player_state_changed', (state) => {
                if (!state) return;
                post({
                  event: 'player_state',
                  sequence: ++playerStateSequence,
                  event_timestamp_ms: Date.now(),
                  paused: state.paused,
                  position_ms: state.position,
                  duration_ms: state.duration,
                  track_uri: state.track_window?.current_track?.uri ?? null
                });
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

enum WebPlaybackCommand {
    case pause
    case resume
    case seek(Int)
    case next
    case previous

    var description: String {
        switch self {
        case .pause: "pause"
        case .resume: "resume"
        case .seek(let positionMs): "seek to \(positionMs)ms"
        case .next: "next"
        case .previous: "previous"
        }
    }
}
