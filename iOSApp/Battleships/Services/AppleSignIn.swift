import AuthenticationServices
import BattleshipAPI
import CryptoKit
import Foundation

/// Sign in with Apple. The app asks Apple for no name or email: the server only needs to recognise
/// the Apple account, and the player picks a username.
enum AppleSignIn {
    enum Failure: LocalizedError {
        case missingToken

        var errorDescription: String? {
            "Sign in with Apple didn't work. Please try again."
        }
    }

    /// Sets up the request: no personal details, and the hash of a fresh nonce, which ties the
    /// identity token Apple issues to this one sign-in.
    static func prepare(_ request: ASAuthorizationAppleIDRequest, nonce: String) {
        request.requestedScopes = []
        request.nonce = sha256(nonce)
    }

    /// What to send the server, and the Apple ID behind it.
    static func signInRequest(from authorization: ASAuthorization, nonce: String) throws -> (request: AppleSignInRequest, appleUserID: String) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
        else { throw Failure.missingToken }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        return (AppleSignInRequest(identityToken: identityToken, authorizationCode: code, nonce: nonce), credential.user)
    }

    static func isCancellation(_ error: any Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    static func message(for error: any Error) -> String {
        switch (error as? ASAuthorizationError)?.code {
        case .unknown:
            // Usually no Apple Account on the device, or a build without the capability.
            "Sign in with Apple isn't available right now. Check that you're signed in to your Apple Account in Settings."
        default:
            "Sign in with Apple didn't work. Please try again."
        }
    }

    /// Whether the player has stopped using their Apple ID with the app (in Settings, or by
    /// signing out of their Apple Account). Errors count as "still fine": being offline mustn't
    /// sign anyone out.
    static func hasStoppedUsingAppleID(_ appleUserID: String) async -> Bool {
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID)
            return state == .revoked || state == .notFound
        } catch {
            return false
        }
    }

    /// A random string for one sign-in.
    static func makeNonce() -> String {
        randomToken()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 32 random bytes, base64url-encoded: 43 characters, safe in URLs.
func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "The system's random number generator failed")
    return Data(bytes).base64URLEncoded()
}

extension Data {
    /// Base64 with the URL-safe alphabet and no padding (RFC 4648 §5).
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
