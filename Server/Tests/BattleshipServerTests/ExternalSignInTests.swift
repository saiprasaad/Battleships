import BattleshipAPI
@testable import BattleshipServer
import Fluent
import JWTKit
import NIOConcurrencyHelpers
import XCTVapor

/// Sign in with Apple and Google, offline: the tests play both providers with their own RSA keys.
final class ExternalSignInTests: ServerTestCase {
    static let bundleID = "com.example.battleships"
    static let googleClientID = "1234-abcdef.apps.googleusercontent.com"
    static let appleKeyPEM = P256.Signing.PrivateKey().pemRepresentation
    static let environment = [
        "APPLE_BUNDLE_ID": bundleID,
        "APPLE_TEAM_ID": "TEAM123456",
        "APPLE_SIGN_IN_KEY_ID": "KEY1234567",
        "APPLE_SIGN_IN_PRIVATE_KEY": appleKeyPEM,
        "GOOGLE_IOS_CLIENT_ID": googleClientID,
    ]

    private var apple: TestIdentityProvider!
    private var google: TestIdentityProvider!

    override func setUp() async throws {
        try await super.setUp()
        apple = try await .apple()
        google = try await .google()
        await keySets.publish(apple.keySet, at: IdentityTokenIssuer.apple(bundleID: Self.bundleID).keySetURL)
        await keySets.publish(google.keySet, at: IdentityTokenIssuer.google(clientID: Self.googleClientID).keySetURL)
        try await restartApp(environment: Self.environment)
    }

    // MARK: Signing in

    func testProvidersReflectTheConfiguration() async throws {
        var providers = try await get(AuthProviders.self, "v1/auth/providers")
        XCTAssertEqual(providers, AuthProviders(apple: true, googleClientID: Self.googleClientID))

        try await restartApp(environment: [:])
        providers = try await get(AuthProviders.self, "v1/auth/providers")
        XCTAssertEqual(providers, .none)

        try await restartApp(environment: ["APPLE_BUNDLE_ID": Self.bundleID])
        providers = try await get(AuthProviders.self, "v1/auth/providers")
        XCTAssertEqual(providers, AuthProviders(apple: true))
    }

    func testSignInWithAppleCreatesAnAccountThenSignsIn() async throws {
        let first = try await signInWithApple(subject: "001234.apple-user", code: "code-1")
        XCTAssertNil(first.session)
        let ticket = try XCTUnwrap(first.signupTicket)
        let suggestion = try XCTUnwrap(first.suggestedUsername)
        XCTAssertNil(CredentialPolicy.usernameProblem(suggestion))
        XCTAssertTrue(ExternalSignInController.suggestionStems.contains { suggestion.hasPrefix($0) })
        let exchanged = await appleTokens.exchangedCodes
        XCTAssertEqual(exchanged, ["code-1"])

        let (status, auth) = try await completeSignup(ticket: ticket, username: "Sailor_Sam")
        XCTAssertEqual(status, .created)
        let session = try XCTUnwrap(auth)
        XCTAssertEqual(session.account.username, "Sailor_Sam")
        try await app.testable().test(.GET, "v1/me", headers: bearer(session.token)) { res async throws in
            XCTAssertEqual(try res.content.decode(Account.self).id, session.account.id)
        }
        let identity = try await XCTUnwrapAsync(await ExternalIdentity.query(on: app.db).first())
        XCTAssertEqual(identity.$user.id, session.account.id)
        XCTAssertEqual(identity.providerRaw, "apple")
        XCTAssertEqual(identity.subject, "001234.apple-user")
        XCTAssertEqual(identity.appleRefreshToken, "refresh-for-code-1")

        // Next time: straight in, without another code exchange.
        let again = try await signInWithApple(subject: "001234.apple-user", code: "code-2")
        XCTAssertNil(again.signupTicket)
        XCTAssertEqual(again.session?.account.id, session.account.id)
        XCTAssertNotEqual(again.session?.token, session.token)
        let exchangedAgain = await appleTokens.exchangedCodes
        XCTAssertEqual(exchangedAgain, ["code-1"])
    }

    func testSignInWithGoogleCreatesAnAccountThenSignsIn() async throws {
        let first = try await signInWithGoogle(subject: "109876543210")
        let ticket = try XCTUnwrap(first.signupTicket)
        let (status, auth) = try await completeSignup(ticket: ticket, username: "Google_Gary")
        XCTAssertEqual(status, .created)
        let account = try XCTUnwrap(auth).account

        let again = try await signInWithGoogle(subject: "109876543210")
        XCTAssertEqual(again.session?.account.id, account.id)
        let identity = try await XCTUnwrapAsync(await ExternalIdentity.query(on: app.db).first())
        XCTAssertEqual(identity.providerRaw, "google")
        XCTAssertNil(identity.appleRefreshToken)
        let exchanged = await appleTokens.exchangedCodes
        XCTAssertEqual(exchanged, [])

        // The same subject at Apple is a different account.
        let apple = try await signInWithApple(subject: "109876543210", code: nil)
        XCTAssertNotNil(apple.signupTicket)
    }

    func testAFailedCodeExchangeIsRetriedAtTheNextSignIn() async throws {
        await appleTokens.refuseExchanges(true)
        let first = try await signInWithApple(subject: "001234.apple-user", code: "code-1")
        _ = try await signUp(ticket: try XCTUnwrap(first.signupTicket), username: "Sailor_Sam")
        var identity = try await XCTUnwrapAsync(await ExternalIdentity.query(on: app.db).first())
        XCTAssertNil(identity.appleRefreshToken, "signing up still works")

        await appleTokens.refuseExchanges(false)
        _ = try await signInWithApple(subject: "001234.apple-user", code: "code-2")
        identity = try await XCTUnwrapAsync(await ExternalIdentity.query(on: app.db).first())
        XCTAssertEqual(identity.appleRefreshToken, "refresh-for-code-2")
    }

    // MARK: Signup tickets

    func testSignupTicketsAreSingleUseAndExpire() async throws {
        let first = try await signInWithApple(subject: "apple-1")
        let ticket = try XCTUnwrap(first.signupTicket)
        _ = try await completeSignup(ticket: ticket, username: "First_Mate")
        let (reusedStatus, _) = try await completeSignup(ticket: ticket, username: "Second_Mate", expecting: .signupTicketInvalid)
        XCTAssertEqual(reusedStatus, .badRequest)

        let late = try await googleTicket(subject: "google-1")
        try await SignupTicket.query(on: app.db)
            .filter(\.$ticketHash == UserToken.hash(late))
            .set(\.$expiresAt, to: Date().addingTimeInterval(-1))
            .update()
        let (expiredStatus, _) = try await completeSignup(ticket: late, username: "Late_Comer", expecting: .signupTicketInvalid)
        XCTAssertEqual(expiredStatus, .gone)

        let (madeUpStatus, _) = try await completeSignup(ticket: "not-a-ticket", username: "Stowaway", expecting: .signupTicketInvalid)
        XCTAssertEqual(madeUpStatus, .badRequest)
    }

    func testSignupUsernamesFollowTheUsualRules() async throws {
        try await register("Sailor_Sam")
        let ticket = try await appleTicket(subject: "apple-1")

        _ = try await completeSignup(ticket: ticket, username: "sailor_sam", expecting: .usernameTaken)
        _ = try await completeSignup(ticket: ticket, username: "big_bastard", expecting: .invalidUsername)
        _ = try await completeSignup(ticket: ticket, username: "admin", expecting: .invalidUsername)
        _ = try await completeSignup(ticket: ticket, username: "no spaces", expecting: .invalidUsername)
        // None of that used up the ticket.
        let (status, auth) = try await completeSignup(ticket: ticket, username: "Sailor_Sue")
        XCTAssertEqual(status, .created)
        XCTAssertEqual(auth?.account.username, "Sailor_Sue")
    }

    func testFinishingASecondSignupForTheSameAccountSignsIn() async throws {
        // Two devices start signing up with the same Apple ID before either finishes.
        let phone = try await appleTicket(subject: "apple-1")
        let tablet = try await appleTicket(subject: "apple-1")
        let (_, created) = try await completeSignup(ticket: phone, username: "Sailor_Sam")
        let (status, signedIn) = try await completeSignup(ticket: tablet, username: "Sailor_Sue")
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(signedIn?.account.id, created?.account.id)
        XCTAssertEqual(signedIn?.account.username, "Sailor_Sam")
        let users = try await User.query(on: app.db).count()
        XCTAssertEqual(users, 1)
    }

    func testAccountsMadeWithAppleOrGoogleHaveNoPassword() async throws {
        let ticket = try await appleTicket(subject: "apple-1")
        _ = try await completeSignup(ticket: ticket, username: "Sailor_Sam")
        let user = try await XCTUnwrapAsync(await User.query(on: app.db).first())
        XCTAssertFalse(user.hasPassword)

        for password in [User.noPassword, "", "correct horse battery", user.passwordHash] {
            try await app.testable().test(.POST, "v1/auth/login", beforeRequest: { req in
                try req.content.encode(Credentials(username: "Sailor_Sam", password: password))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(try res.content.decode(APIErrorBody.self).code, .invalidCredentials)
            })
        }
    }

    // MARK: Deleting accounts

    func testDeletingAnAccountRevokesSignInWithApple() async throws {
        let ticket = try await appleTicket(subject: "apple-1", code: "code-1")
        let session = try await signUp(ticket: ticket, username: "Sailor_Sam")

        try await app.testable().test(.DELETE, "v1/me", headers: bearer(session.token)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        let revoked = await appleTokens.revokedTokens
        XCTAssertEqual(revoked, ["refresh-for-code-1"])
        let identities = try await ExternalIdentity.query(on: app.db).count()
        XCTAssertEqual(identities, 0)

        // Signing in with that Apple ID again starts a new account.
        let again = try await signInWithApple(subject: "apple-1", code: "code-2")
        XCTAssertNotNil(again.signupTicket)
    }

    func testAdministratorsDeletingAnAccountRevokesSignInWithApple() async throws {
        let adminToken = "an-admin-token-for-tests-0123456789"
        try await restartApp(environment: Self.environment.merging(["ADMIN_TOKEN": adminToken]) { $1 })
        let ticket = try await appleTicket(subject: "apple-1", code: "code-9")
        let session = try await signUp(ticket: ticket, username: "Sailor_Sam")

        try await app.testable().test(.DELETE, "v1/admin/players/\(session.account.id)", headers: bearer(adminToken)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        let revoked = await appleTokens.revokedTokens
        XCTAssertEqual(revoked, ["refresh-for-code-9"])
    }

    func testWithoutTheAppleKeyThereIsNothingToExchangeOrRevoke() async throws {
        try await restartApp(environment: ["APPLE_BUNDLE_ID": Self.bundleID])
        let ticket = try await appleTicket(subject: "apple-1", code: "code-1")
        let session = try await signUp(ticket: ticket, username: "Sailor_Sam")
        try await app.testable().test(.DELETE, "v1/me", headers: bearer(session.token)) { res async in
            XCTAssertEqual(res.status, .noContent)
        }
        let exchanged = await appleTokens.exchangedCodes
        let revoked = await appleTokens.revokedTokens
        XCTAssertEqual(exchanged, [])
        XCTAssertEqual(revoked, [])
    }

    // MARK: Availability

    func testUnconfiguredMethodsAreUnavailable() async throws {
        try await restartApp(environment: [:])
        let appleToken = try await apple.token(subject: "apple-1", nonce: "n".sha256Hex)
        let (appleStatus, appleError) = try await post("v1/auth/apple", AppleSignInRequest(identityToken: appleToken, authorizationCode: nil, nonce: "n"))
        XCTAssertEqual(appleStatus, .notFound)
        XCTAssertEqual(try decode(APIErrorBody.self, appleError).code, .signInMethodUnavailable)

        let googleToken = try await google.token(subject: "google-1", nonce: "n")
        let (googleStatus, googleError) = try await post("v1/auth/google", GoogleSignInRequest(idToken: googleToken, nonce: "n"))
        XCTAssertEqual(googleStatus, .notFound)
        XCTAssertEqual(try decode(APIErrorBody.self, googleError).code, .signInMethodUnavailable)
    }

    func testAnUnreachableProviderIsReportedAsUnavailable() async throws {
        await keySets.unpublish(IdentityTokenIssuer.google(clientID: Self.googleClientID).keySetURL)
        let token = try await google.token(subject: "google-1", nonce: "n")
        let (status, body) = try await post("v1/auth/google", GoogleSignInRequest(idToken: token, nonce: "n"))
        XCTAssertEqual(status, .serviceUnavailable)
        XCTAssertEqual(try decode(APIErrorBody.self, body).code, .signInMethodUnavailable)
    }

    // MARK: Token checks

    func testTokensThatDontCheckOutAreRejected() async throws {
        let nonce = "the-nonce"
        let other = try await TestIdentityProvider.apple(keyID: apple.keyID)
        let cases: [(String, String)] = [
            ("wrong audience", try await apple.token(subject: "a", nonce: nonce.sha256Hex, audience: "com.example.other")),
            ("wrong issuer", try await apple.token(subject: "a", nonce: nonce.sha256Hex, issuer: "https://accounts.google.com")),
            ("expired", try await apple.token(subject: "a", nonce: nonce.sha256Hex, expiresIn: -(JWKSIdentityTokenVerifier.clockLeeway + 60))),
            ("raw nonce", try await apple.token(subject: "a", nonce: nonce)),
            ("no nonce", try await apple.token(subject: "a", nonce: nil)),
            ("another nonce", try await apple.token(subject: "a", nonce: "another".sha256Hex)),
            ("signed with someone else's key", try await other.token(subject: "a", nonce: nonce.sha256Hex)),
            ("unknown key", try await apple.token(subject: "a", nonce: nonce.sha256Hex, keyID: "not-a-published-key")),
            ("not a JWT", "not.a.jwt"),
        ]
        for (problem, token) in cases {
            let (status, body) = try await post("v1/auth/apple", AppleSignInRequest(identityToken: token, authorizationCode: "code", nonce: nonce))
            XCTAssertEqual(status, .unauthorized, problem)
            XCTAssertEqual(try decode(APIErrorBody.self, body).code, .invalidIdentityToken, problem)
        }
        let exchanged = await appleTokens.exchangedCodes
        XCTAssertEqual(exchanged, [], "codes from rejected sign-ins aren't exchanged")

        // A token within the clock leeway still counts.
        let (status, _) = try await post("v1/auth/apple", AppleSignInRequest(
            identityToken: try await apple.token(subject: "a", nonce: nonce.sha256Hex, expiresIn: -(JWKSIdentityTokenVerifier.clockLeeway / 2)),
            authorizationCode: nil,
            nonce: nonce
        ))
        XCTAssertEqual(status, .ok)
    }

    func testGoogleNoncesMustMatchExactly() async throws {
        let token = try await google.token(subject: "google-1", nonce: "nonce-1".sha256Hex)
        let (status, body) = try await post("v1/auth/google", GoogleSignInRequest(idToken: token, nonce: "nonce-1"))
        XCTAssertEqual(status, .unauthorized)
        XCTAssertEqual(try decode(APIErrorBody.self, body).code, .invalidIdentityToken)
        let issuers = try await google.token(subject: "google-1", nonce: "nonce-1", issuer: "accounts.google.com")
        let (plainIssuer, _) = try await post("v1/auth/google", GoogleSignInRequest(idToken: issuers, nonce: "nonce-1"))
        XCTAssertEqual(plainIssuer, .ok, "Google uses both forms of its issuer")
    }

    func testKeysAreFetchedAgainForRotationButNotForEveryUnknownKey() async throws {
        let clock = NIOLockedValueBox(Date())
        let verifier = JWKSIdentityTokenVerifier(
            .apple(bundleID: Self.bundleID),
            fetcher: keySets,
            logger: app.logger,
            now: { clock.withLockedValue { $0 } }
        )
        let url = IdentityTokenIssuer.apple(bundleID: Self.bundleID).keySetURL
        func fetches() async -> Int {
            await keySets.fetches.filter { $0 == url.string }.count
        }
        func accepts(_ token: String) async -> Bool {
            (try? await verifier.subject(of: token, nonce: "n")) != nil
        }

        let accepted = await accepts(try await apple.token(subject: "apple-1", nonce: "n"))
        XCTAssertTrue(accepted)
        var count = await fetches()
        XCTAssertEqual(count, 1)

        // Apple starts signing with a new key. Straight after a fetch it isn't fetched again, so
        // tokens naming made-up keys can't make the server hammer Apple...
        let rotated = try await TestIdentityProvider.apple(keyID: "apple-key-2")
        await keySets.publish(JWKS(keys: apple.keySet.keys + rotated.keySet.keys), at: url)
        let tooSoon = await accepts(try await rotated.token(subject: "apple-2", nonce: "n"))
        XCTAssertFalse(tooSoon)
        count = await fetches()
        XCTAssertEqual(count, 1)

        // ...but a minute later the new key is fetched and accepted.
        clock.withLockedValue { $0 += JWKSIdentityTokenVerifier.refetchInterval + 1 }
        let rotatedAccepted = await accepts(try await rotated.token(subject: "apple-2", nonce: "n"))
        XCTAssertTrue(rotatedAccepted)
        count = await fetches()
        XCTAssertEqual(count, 2)
        for index in 0..<3 {
            let madeUp = await accepts(try await apple.token(subject: "x", nonce: "n", keyID: "made-up-\(index)"))
            XCTAssertFalse(madeUp)
        }
        count = await fetches()
        XCTAssertEqual(count, 2)

        // Known keys are fetched again once they're a day old.
        clock.withLockedValue { $0 += JWKSIdentityTokenVerifier.maximumKeyAge + 1 }
        let afterADay = await accepts(try await apple.token(subject: "apple-1", nonce: "n", expiresIn: JWKSIdentityTokenVerifier.maximumKeyAge * 2))
        XCTAssertTrue(afterADay)
        count = await fetches()
        XCTAssertEqual(count, 3)
    }

    // MARK: Apple's token API

    func testAppleTokenRequestsAreSignedWithTheSignInWithAppleKey() async throws {
        let key = ServerSettings.AppleSignInKey(teamID: "TEAM123456", keyID: "KEY1234567", privateKeyPEM: Self.appleKeyPEM)
        let sent = SentForms()
        let service = try await AppleTokenService(bundleID: Self.bundleID, key: key) { url, form in
            await sent.append(url, form)
            if url.string == AppleTokenService.tokenURL.string {
                return (.ok, ByteBuffer(string: #"{"access_token":"a","token_type":"Bearer","expires_in":3600,"refresh_token":"r-123","id_token":"i"}"#))
            }
            return (.ok, nil)
        }

        let refreshToken = try await service.refreshToken(forAuthorizationCode: "the-code")
        XCTAssertEqual(refreshToken, "r-123")
        try await service.revoke(refreshToken: "r-123")

        let forms = await sent.forms
        XCTAssertEqual(forms.map(\.url), [AppleTokenService.tokenURL.string, AppleTokenService.revokeURL.string])
        XCTAssertEqual(forms[0].form["client_id"], Self.bundleID)
        XCTAssertEqual(forms[0].form["code"], "the-code")
        XCTAssertEqual(forms[0].form["grant_type"], "authorization_code")
        XCTAssertEqual(forms[1].form["token"], "r-123")
        XCTAssertEqual(forms[1].form["token_type_hint"], "refresh_token")

        // The client secret is an ES256 JWT from the Sign in with Apple key, as Apple specifies.
        let verifier = JWTKeyCollection()
        await verifier.add(ecdsa: try ES256PrivateKey(pem: Self.appleKeyPEM).publicKey, kid: JWKIdentifier(string: key.keyID))
        for form in forms {
            let secret = try XCTUnwrap(form.form["client_secret"])
            let claims = try await verifier.verify(secret, as: AppleClientSecret.self)
            XCTAssertEqual(claims.iss.value, "TEAM123456")
            XCTAssertEqual(claims.sub.value, Self.bundleID)
            XCTAssertEqual(claims.aud.value, ["https://appleid.apple.com"])
            XCTAssertLessThanOrEqual(claims.exp.value.timeIntervalSince(claims.iat.value), 15_777_000)
            let header = try DefaultJWTParser().parse(Array(secret.utf8), as: AppleClientSecret.self).header
            XCTAssertEqual(header.alg, "ES256")
            XCTAssertEqual(header.kid, "KEY1234567")
        }
    }

    func testAppleErrorsDontRevealTokens() async throws {
        let key = ServerSettings.AppleSignInKey(teamID: "TEAM123456", keyID: "KEY1234567", privateKeyPEM: Self.appleKeyPEM)
        let service = try await AppleTokenService(bundleID: Self.bundleID, key: key) { _, _ in
            (.badRequest, ByteBuffer(string: #"{"error":"invalid_grant"}"#))
        }
        do {
            try await service.revoke(refreshToken: "secret-refresh-token")
            XCTFail("Expected Apple to refuse")
        } catch {
            XCTAssertEqual("\(error)", "Apple answered 400 (invalid_grant)")
        }
    }

    // MARK: Helpers

    private func signInWithApple(subject: String, code: String? = "code-1") async throws -> ExternalSignInResponse {
        let nonce = UUID().uuidString
        let token = try await apple.token(subject: subject, nonce: nonce.sha256Hex)
        let (status, body) = try await post("v1/auth/apple", AppleSignInRequest(identityToken: token, authorizationCode: code, nonce: nonce))
        XCTAssertEqual(status, .ok, body.string)
        return try decode(ExternalSignInResponse.self, body)
    }

    private func signInWithGoogle(subject: String) async throws -> ExternalSignInResponse {
        let nonce = UUID().uuidString
        let token = try await google.token(subject: subject, nonce: nonce)
        let (status, body) = try await post("v1/auth/google", GoogleSignInRequest(idToken: token, nonce: nonce))
        XCTAssertEqual(status, .ok, body.string)
        return try decode(ExternalSignInResponse.self, body)
    }

    private func appleTicket(subject: String, code: String? = "code-1") async throws -> String {
        let response = try await signInWithApple(subject: subject, code: code)
        return try XCTUnwrap(response.signupTicket)
    }

    private func googleTicket(subject: String) async throws -> String {
        let response = try await signInWithGoogle(subject: subject)
        return try XCTUnwrap(response.signupTicket)
    }

    /// Completes a signup that's expected to work.
    private func signUp(ticket: String, username: String) async throws -> AuthResponse {
        let (_, auth) = try await completeSignup(ticket: ticket, username: username)
        return try XCTUnwrap(auth)
    }

    /// Completes a signup; with `expecting`, asserts it fails with that code.
    @discardableResult
    private func completeSignup(
        ticket: String,
        username: String,
        expecting code: APIErrorCode? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (HTTPStatus, AuthResponse?) {
        let (status, body) = try await post("v1/auth/complete-signup", CompleteSignupRequest(signupTicket: ticket, username: username))
        if let code {
            XCTAssertEqual(try decode(APIErrorBody.self, body).code, code, file: file, line: line)
            return (status, nil)
        }
        XCTAssertTrue([.ok, .created].contains(status), body.string, file: file, line: line)
        return (status, try decode(AuthResponse.self, body))
    }

    private func post(_ path: String, _ content: some Content) async throws -> (HTTPStatus, ByteBuffer) {
        var result: (HTTPStatus, ByteBuffer)?
        try await app.testable().test(.POST, path, beforeRequest: { req in
            try req.content.encode(content)
        }, afterResponse: { res async in
            result = (res.status, res.body)
        })
        return try XCTUnwrap(result)
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        var body: ByteBuffer?
        try await app.testable().test(.GET, path) { res async in
            XCTAssertEqual(res.status, .ok)
            body = res.body
        }
        return try decode(T.self, try XCTUnwrap(body))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ body: ByteBuffer) throws -> T {
        try APICoding.makeDecoder().decode(T.self, from: Data(buffer: body))
    }
}

/// The forms an ``AppleTokenService`` sent.
private actor SentForms {
    private(set) var forms: [(url: String, form: [String: String])] = []

    func append(_ url: URI, _ form: [String: String]) {
        forms.append((url.string, form))
    }
}
