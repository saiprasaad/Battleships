import AuthenticationServices
import BattleshipAPI
import CryptoKit
import Foundation
import SwiftUI

/// Sign in with Google, without Google's SDK: the standard OAuth flow for native apps (RFC 8252)
/// in the system's sign-in sheet, protected with PKCE, asking only for the `openid` scope, so
/// Google shares nothing but an identifier for the account.
///
/// The client ID belongs to an OAuth client of type "iOS" in Google Cloud; the server tells the app
/// which one to use (``AuthProviders/googleClientID``).
struct GoogleSignIn {
    enum Failure: LocalizedError {
        case unexpectedResponse
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse:
                "Google sent an unexpected answer. Please try again."
            case let .refused(reason):
                "Google didn't sign you in (\(reason)). Please try again."
            }
        }
    }

    let clientID: String

    /// iOS clients redirect to their client ID reversed, e.g. `com.googleusercontent.apps.123-abc`.
    var callbackScheme: String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    var redirectURI: String {
        "\(callbackScheme):/oauth2redirect"
    }

    /// Shows Google's sign-in page and returns the ID token for the server. Throws
    /// `CancellationError` if the player backs out.
    @MainActor
    func signIn(using session: WebAuthenticationSession) async throws -> GoogleSignInRequest {
        let verifier = randomToken()
        let state = randomToken()
        let nonce = randomToken()

        var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = authorization.url else { throw Failure.unexpectedResponse }

        let callback: URL
        do {
            if #available(iOS 17.4, *) {
                callback = try await session.authenticate(
                    using: url,
                    callback: .customScheme(callbackScheme),
                    preferredBrowserSession: nil,
                    additionalHeaderFields: [:]
                )
            } else {
                callback = try await session.authenticate(using: url, callbackURLScheme: callbackScheme)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw CancellationError()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            if error == "access_denied" { throw CancellationError() }
            throw Failure.refused(error)
        }
        // The state proves the answer is for the request this app just made.
        guard value("state") == state, let code = value("code") else { throw Failure.unexpectedResponse }
        let idToken = try await idToken(exchanging: code, verifier: verifier)
        return GoogleSignInRequest(idToken: idToken, nonce: nonce)
    }

    private func idToken(exchanging code: String, verifier: String) async throws -> String {
        struct TokenResponse: Decodable {
            let idToken: String?
            let error: String?

            enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
                case error
            }
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
        ]).utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if let idToken = response?.idToken {
            return idToken
        }
        throw response?.error.map(Failure.refused) ?? Failure.unexpectedResponse
    }

    /// The PKCE code challenge: the verifier's SHA-256, base64url-encoded.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
    }
}
