import CloudCore
import CryptoKit
import Foundation
import HTTPTypes

/// Immich's single sign-on (OAuth / OpenID Connect), using the same mobile flow as the official app:
///
/// 1. `POST /oauth/authorize` with a redirect, a `state` and a PKCE code challenge returns the
///    identity provider's sign-in page.
/// 2. The page is shown in a browser sheet; the identity provider sends the browser back to
///    `app.immich:///oauth-callback?code=…&state=…` (directly, or through the server's
///    `/oauth/mobile-redirect` when the "mobile redirect URI override" is on).
/// 3. `POST /oauth/callback` with that URL, the state and the code verifier returns a session,
///    exactly like `POST /auth/login`.
///
/// These operations aren't in the generated client, so they are plain URLSession calls.
public enum ImmichOAuth {
    /// The official app's redirect. Identity providers set up for Immich's mobile app already
    /// allow it, and the server's mobile redirect override replaces exactly this value.
    public static let callbackScheme = "app.immich"
    public static let redirectURI = "app.immich:///oauth-callback"

    /// Which sign-in methods the server has turned on.
    public struct LoginOptions: Sendable, Equatable {
        public let password: Bool
        public let oauth: Bool
        /// The server's label for the OAuth button ("Login with OAuth" unless the admin changed it).
        public let buttonText: String?
    }

    /// A started sign-in: the page to open and the secrets needed to finish it.
    public struct Authorization: Sendable, Equatable {
        public let url: URL
        public let state: String
        public let codeVerifier: String
    }

    // MARK: Calls

    /// `GET /server/features` (and `GET /server/config` for the button's label). Needs no sign-in.
    public static func loginOptions(server: URL, session: URLSession) async throws -> LoginOptions {
        let features: FeaturesBody = try await send(
            getRequest(server: server, path: "server/features"), session: session, operation: "read the sign-in options"
        )
        let oauth = features.oauth ?? false
        var buttonText: String?
        if oauth {
            // Only the label: without it the app's own wording is used.
            let config: ConfigBody? = try? await send(
                getRequest(server: server, path: "server/config"), session: session, operation: "read the server settings"
            )
            buttonText = config?.oauthButtonText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if buttonText?.isEmpty == true { buttonText = nil }
        }
        return LoginOptions(password: features.passwordLogin ?? true, oauth: oauth, buttonText: buttonText)
    }

    /// `POST /oauth/authorize`: starts a sign-in with a fresh state and PKCE pair.
    public static func authorize(server: URL, session: URLSession) async throws -> Authorization {
        let state = randomToken()
        let codeVerifier = randomToken()
        let body = AuthorizeBody(redirectUri: redirectURI, state: state, codeChallenge: codeChallenge(for: codeVerifier))
        let response: AuthorizeResponse = try await send(
            try postRequest(server: server, path: "oauth/authorize", json: body), session: session, operation: "start single sign-on"
        )
        guard let url = URL(string: response.url), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw APIError(
                kind: .decoding,
                message: "The server's single sign-on page address could not be used. Check the OAuth settings on the server."
            )
        }
        return Authorization(url: url, state: state, codeVerifier: codeVerifier)
    }

    /// `POST /oauth/callback`: exchanges the identity provider's answer for an Immich session.
    public static func finish(
        callbackURL: URL, state: String, codeVerifier: String, server: URL, session: URLSession
    ) async throws -> LoginResult {
        let url = try callbackForServer(callbackURL, expectedState: state)
        let body = CallbackBody(url: url, state: state, codeVerifier: codeVerifier)
        let dto: LoginResponse = try await send(
            try postRequest(server: server, path: "oauth/callback", json: body), session: session, operation: "finish single sign-on"
        )
        return LoginResult(accessToken: dto.accessToken, userID: dto.userId, email: dto.userEmail, name: dto.name, isAdmin: dto.isAdmin)
    }

    // MARK: Pieces (internal for tests)

    /// Checks the identity provider's answer and rebuilds it as the server expects it: the exact
    /// redirect URI sent at the start (`app.immich:///oauth-callback`, three slashes) plus its query.
    /// iOS can hand the URL back as `app.immich:/oauth-callback?…`; the token exchange would then
    /// send a redirect URI the identity provider doesn't recognise.
    static func callbackForServer(_ callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, !query.isEmpty
        else {
            throw APIError(kind: .decoding, message: "Single sign-on came back without an answer from the identity provider.")
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            let detail = value("error_description").map { ": \($0)" } ?? " (\(error))"
            throw APIError(kind: .unauthorized, message: "The identity provider refused the sign-in\(detail).")
        }
        guard value("state") == expectedState else {
            throw APIError(kind: .unauthorized, message: "Single sign-on answered for a different sign-in attempt. Try again.")
        }
        guard value("code")?.isEmpty == false else {
            throw APIError(kind: .decoding, message: "Single sign-on came back without a sign-in code.")
        }
        return "\(redirectURI)?\(query)"
    }

    /// 32 random bytes, base64url: an OAuth `state` or a PKCE code verifier (43 characters).
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// PKCE `S256`: base64url(SHA-256(verifier)).
    static func codeChallenge(for codeVerifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: HTTP

    private static func getRequest(server: URL, path: String) -> URLRequest {
        var request = URLRequest(url: ImmichClient.apiURL(for: server).appending(path: path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in DeviceHeaders.values {
            request.setValue(value, forHTTPHeaderField: name.rawName)
        }
        return request
    }

    private static func postRequest(server: URL, path: String, json body: some Encodable) throws -> URLRequest {
        var request = getRequest(server: server, path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func send<Response: Decodable>(
        _ request: URLRequest, session: URLSession, operation: String
    ) async throws -> Response {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw APIError.wrap(error, operation: "Single sign-on")
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw APIError(kind: .transport, message: "Single sign-on: the server's answer could not be read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.from(statusCode: http.statusCode, body: data, operation: operation)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.wrap(error, operation: "Single sign-on")
        }
    }

    // MARK: Bodies (only the fields used; missing ones don't fail older or newer servers)

    private struct FeaturesBody: Decodable {
        let passwordLogin: Bool?
        let oauth: Bool?
    }

    private struct ConfigBody: Decodable {
        let oauthButtonText: String?
    }

    private struct AuthorizeBody: Encodable {
        let redirectUri: String
        let state: String
        let codeChallenge: String
    }

    private struct AuthorizeResponse: Decodable {
        let url: String
    }

    private struct CallbackBody: Encodable {
        let url: String
        let state: String
        let codeVerifier: String
    }

    private struct LoginResponse: Decodable {
        let accessToken: String
        let userId: String
        let userEmail: String
        let name: String
        let isAdmin: Bool
    }
}
