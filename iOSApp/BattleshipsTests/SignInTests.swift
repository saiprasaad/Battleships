#if canImport(UIKit)
import Foundation
import Testing
@testable import Battleships

@Suite("Signing in with Apple and Google")
struct SignInTests {
    @Test func googleRedirectsToTheReversedClientID() {
        let google = GoogleSignIn(clientID: "123456-abc.apps.googleusercontent.com")
        #expect(google.callbackScheme == "com.googleusercontent.apps.123456-abc")
        #expect(google.redirectURI == "com.googleusercontent.apps.123456-abc:/oauth2redirect")
    }

    @Test func pkceChallengeIsTheVerifiersHash() {
        // SHA-256, base64url without padding (RFC 7636 §4.2).
        #expect(GoogleSignIn.challenge(for: "a-fixed-verifier_for.tests~1234567890abcdefghijk") == "QQ3FP_S8GpGuMimwtGfCvLWPCE_11eBwn818ZvU5gfk")
    }

    @Test func tokenRequestsAreFormEncoded() {
        let body = GoogleSignIn.formEncoded([("code", "4/0Ab+c d"), ("redirect_uri", "com.example:/oauth2redirect")])
        #expect(body == "code=4%2F0Ab%2Bc%20d&redirect_uri=com.example%3A%2Foauth2redirect")
    }

    @Test func appleGetsTheNoncesHash() {
        #expect(AppleSignIn.sha256("nonce") == "78377b525757b494427f89014f97d79928f3938d14eb51e20fb5dec9834eb304")
        let nonce = AppleSignIn.makeNonce()
        #expect(nonce.count == 43)
        #expect(nonce != AppleSignIn.makeNonce())
        #expect(nonce.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}
#endif
