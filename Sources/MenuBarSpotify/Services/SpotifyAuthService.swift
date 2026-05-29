import AppKit
import AuthenticationServices
import Foundation
import OSLog

@MainActor
final class SpotifyAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let logger = Logger(subsystem: "com.yashasbhat.MenuBarSpotify", category: "auth")
    private static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    private static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    private static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-read-playback-state",
        "user-read-currently-playing",
        "user-read-recently-played",
        "streaming",
        "user-modify-playback-state",
        "playlist-modify-private",
        "playlist-modify-public"
    ]

    private var session: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackScheme: String?
    private let anchorWindow = NSWindow()

    func signIn(config: SpotifyConfig) async throws -> SpotifyConfig {
        guard !config.clientID.isEmpty else {
            throw SpotifyError.missingConfig("Missing SPOTIFY_CLIENT_ID in .config")
        }
        guard !config.clientSecret.isEmpty else {
            throw SpotifyError.missingConfig("Missing SPOTIFY_CLIENT_SECRET in .config")
        }

        let authURL = try authorizationURL(config: config)
        guard let callbackScheme = URL(string: config.redirectURI)?.scheme else {
            throw SpotifyError.authFailed("Spotify redirect URI is missing a URL scheme.")
        }

        let callbackURL = try await callback(from: authURL, scheme: callbackScheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value else {
            throw SpotifyError.authFailed("Spotify did not return an authorization code.")
        }

        return try await exchangeCode(code, config: config)
    }

    func refresh(config: SpotifyConfig) async throws -> SpotifyConfig {
        guard let refreshToken = config.refreshToken else {
            throw SpotifyError.authFailed("No refresh token available.")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(clientID: config.clientID, clientSecret: config.clientSecret), forHTTPHeaderField: "Authorization")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let response: TokenResponse = try await sendTokenRequest(request)
        var updated = config
        updated.accessToken = response.accessToken
        updated.refreshToken = response.refreshToken ?? refreshToken
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn - 60))
        return updated
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow
    }

    func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme == pendingCallbackScheme,
              let pendingContinuation else {
            return false
        }

        Self.logger.info("Spotify auth callback received through app URL handler.")
        self.pendingContinuation = nil
        self.pendingCallbackScheme = nil
        session?.cancel()
        session = nil
        pendingContinuation.resume(returning: url)
        return true
    }

    private func authorizationURL(config: SpotifyConfig) throws -> URL {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " "))
        ]
        guard let url = components.url else {
            throw SpotifyError.authFailed("Could not create Spotify authorization URL.")
        }
        return url
    }

    private func callback(from authURL: URL, scheme: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Self.logger.info("Starting Spotify auth session for callback scheme: \(scheme ?? "nil", privacy: .public)")
            pendingContinuation = continuation
            pendingCallbackScheme = scheme

            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    Self.logger.info("Spotify auth callback received through ASWebAuthenticationSession.")
                    self.finishCallback(with: .success(callbackURL))
                } else {
                    Self.logger.error("Spotify auth callback failed: \(String(describing: error), privacy: .public)")
                    self.finishCallback(with: .failure(error ?? SpotifyError.authFailed("Sign in was cancelled.")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                Self.logger.error("ASWebAuthenticationSession did not start.")
                finishCallback(with: .failure(SpotifyError.authFailed("Could not start Spotify sign in.")))
                return
            }
        }
    }

    private func finishCallback(with result: Result<URL, Error>) {
        guard let pendingContinuation else {
            return
        }

        self.pendingContinuation = nil
        pendingCallbackScheme = nil
        session = nil

        switch result {
        case .success(let url):
            pendingContinuation.resume(returning: url)
        case .failure(let error):
            pendingContinuation.resume(throwing: error)
        }
    }

    private func exchangeCode(_ code: String, config: SpotifyConfig) async throws -> SpotifyConfig {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(clientID: config.clientID, clientSecret: config.clientSecret), forHTTPHeaderField: "Authorization")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI
        ])

        let response: TokenResponse = try await sendTokenRequest(request)
        var updated = config
        updated.accessToken = response.accessToken
        updated.refreshToken = response.refreshToken
        updated.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn - 60))
        return updated
    }

    private func sendTokenRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyError.networkFailure(from: error) ?? error
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown token error"
            throw SpotifyError.authFailed(body)
        }
        return try JSONDecoder.spotify.decode(T.self, from: data)
    }

    private func basicAuthHeader(clientID: String, clientSecret: String) -> String {
        let raw = "\(clientID):\(clientSecret)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    private func formBody(_ values: [String: String]) -> Data {
        values
            .map { key, value in
                "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case scope
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}
