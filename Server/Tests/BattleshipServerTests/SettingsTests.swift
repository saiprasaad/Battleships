@testable import BattleshipServer
import XCTVapor

/// Settings are read from the environment and rejected at startup when they don't make sense.
final class SettingsTests: XCTestCase {
    private func load(_ variables: [String: String], for environment: Environment = .production) throws -> ServerSettings {
        try ServerSettings.load(for: environment, from: variables)
    }

    private func assertInvalid(
        _ variables: [String: String],
        mentioning text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try load(variables), file: file, line: line) { error in
            guard let error = error as? ConfigurationError else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(error.reason.contains(text), "\"\(error.reason)\" doesn't mention \"\(text)\"", file: file, line: line)
        }
    }

    func testDefaults() throws {
        let settings = try load([:])
        XCTAssertNil(settings.port)
        XCTAssertEqual(settings.database, .sqliteFile(path: "battleships.sqlite"))
        XCTAssertEqual(settings.clientAddressSource, .peer)
        XCTAssertEqual(settings.authRequestsPerMinute, 20)
        XCTAssertEqual(settings.loginAttemptsPerUsernamePerHour, 10)
        XCTAssertEqual(settings.maxOpenGamesPerPlayer, 20)
        XCTAssertEqual(settings.newGamesPerHour, 30)
        XCTAssertEqual(settings.maxPendingChallenges, 20)
        XCTAssertEqual(settings.turnTimeLimit, 72 * 3600)
        XCTAssertNil(settings.apns)
        XCTAssertNil(settings.adminToken)
        XCTAssertNil(settings.supportEmail)
    }

    func testValidValues() throws {
        let settings = try load([
            "PORT": "10000",
            "DATABASE_URL": "postgres://user:secret@db.internal:5432/battleships",
            "TURN_TIME_LIMIT_HOURS": "0.5",
            "MAX_OPEN_GAMES": "5",
            "CLIENT_IP_HEADER": "Fly-Client-IP",
            "SUPPORT_EMAIL": "help@example.com",
            "ADMIN_TOKEN": String(repeating: "k", count: 32),
            "APNS_KEY_ID": "ABC123DEFG",
            "APNS_TEAM_ID": "TEAM123456",
            "APNS_TOPIC": "com.example.battleships",
            "APNS_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----",
        ])
        XCTAssertEqual(settings.port, 10_000)
        XCTAssertEqual(settings.database, .postgres(url: "postgres://user:secret@db.internal:5432/battleships"))
        XCTAssertEqual(settings.turnTimeLimit, 1800)
        XCTAssertEqual(settings.maxOpenGamesPerPlayer, 5)
        XCTAssertEqual(settings.clientAddressSource, .header("Fly-Client-IP"))
        XCTAssertEqual(settings.supportEmail, "help@example.com")
        XCTAssertEqual(settings.apns?.privateKeyPEM, "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----")

        XCTAssertEqual(try load(["TRUSTED_PROXY_COUNT": "1"]).clientAddressSource, .forwardedFor(trustedProxies: 1))
        XCTAssertEqual(try load(["TRUSTED_PROXY_COUNT": "0"]).clientAddressSource, .peer)
        // Blank counts as unset: some platforms can only empty a variable.
        XCTAssertNil(try load(["PORT": "", "ADMIN_TOKEN": " "]).port)
    }

    func testTestsNeverUseTheRealDatabase() throws {
        let settings = try load(["DATABASE_URL": "postgres://prod/battleships"], for: .testing)
        XCTAssertEqual(settings.database, .sqliteInMemory)
        let postgres = try load(["TEST_DATABASE_URL": "postgres://localhost/battleships_test"], for: .testing)
        XCTAssertEqual(postgres.database, .postgres(url: "postgres://localhost/battleships_test"))
    }

    func testInvalidNumbers() {
        for port in ["http", "0", "65536", "-80", "8080.5"] {
            assertInvalid(["PORT": port], mentioning: "PORT must be a whole number from 1 to 65535")
        }
        for hours in ["0", "-1", "nan", "inf", "-inf", "8761", "soon"] {
            assertInvalid(["TURN_TIME_LIMIT_HOURS": hours], mentioning: "TURN_TIME_LIMIT_HOURS must be a number greater than 0 and at most 8760")
        }
        for name in ["MAX_OPEN_GAMES", "AUTH_RATE_LIMIT_PER_MINUTE", "LOGIN_RATE_LIMIT_PER_USERNAME_PER_HOUR", "NEW_GAME_RATE_LIMIT_PER_HOUR", "MAX_PENDING_CHALLENGES"] {
            assertInvalid([name: "0"], mentioning: "\(name) must be a whole number")
            assertInvalid([name: "lots"], mentioning: "\(name) must be a whole number")
        }
        assertInvalid(["TRUSTED_PROXY_COUNT": "-1"], mentioning: "TRUSTED_PROXY_COUNT must be a whole number from 0 to 10")
    }

    func testInvalidChoices() {
        assertInvalid(["DATABASE_URL": "mysql://localhost/battleships"], mentioning: "DATABASE_URL must be a postgres:// URL")
        assertInvalid(["CLIENT_IP_HEADER": "Client IP"], mentioning: "CLIENT_IP_HEADER must be a header name")
        assertInvalid(["CLIENT_IP_HEADER": "x-forwarded-for"], mentioning: "clients can write to it")
        assertInvalid(["CLIENT_IP_HEADER": "Fly-Client-IP", "TRUSTED_PROXY_COUNT": "1"], mentioning: "not both")
        assertInvalid(["ADMIN_TOKEN": "too-short"], mentioning: "ADMIN_TOKEN must be at least 16 characters")
        assertInvalid(["SUPPORT_EMAIL": "support at example dot com"], mentioning: "SUPPORT_EMAIL must be an email address")
    }

    func testHalfConfiguredPushIsAnError() {
        assertInvalid(["APNS_KEY_ID": "ABC123DEFG"], mentioning: "APNS_TEAM_ID, APNS_TOPIC, APNS_PRIVATE_KEY")
        assertInvalid(
            ["APNS_KEY_ID": "A", "APNS_TEAM_ID": "T", "APNS_TOPIC": "com.example", "APNS_PRIVATE_KEY_PATH": "/nonexistent/key.p8"],
            mentioning: "Can't read APNS_PRIVATE_KEY_PATH"
        )
    }

    func testSignInWithAppleAndGoogle() throws {
        let key = P256.Signing.PrivateKey().pemRepresentation
        let full = try load([
            "APPLE_BUNDLE_ID": "com.example.battleships",
            "APPLE_TEAM_ID": "TEAM123456",
            "APPLE_SIGN_IN_KEY_ID": "KEY1234567",
            "APPLE_SIGN_IN_PRIVATE_KEY": key.replacingOccurrences(of: "\n", with: "\\n"),
            "GOOGLE_IOS_CLIENT_ID": "1234-abc.apps.googleusercontent.com",
        ])
        XCTAssertEqual(full.appleSignIn?.bundleID, "com.example.battleships")
        XCTAssertEqual(full.appleSignIn?.key?.privateKeyPEM, key, "escaped newlines are restored")
        XCTAssertEqual(full.googleClientID, "1234-abc.apps.googleusercontent.com")

        let withoutKey = try load(["APPLE_BUNDLE_ID": "com.example.battleships"])
        XCTAssertNotNil(withoutKey.appleSignIn)
        XCTAssertNil(withoutKey.appleSignIn?.key)
        XCTAssertNil(try load([:]).appleSignIn)

        assertInvalid(["APPLE_BUNDLE_ID": "com.example.battleships", "APPLE_TEAM_ID": "TEAM123456"], mentioning: "Also set APPLE_SIGN_IN_KEY_ID, APPLE_SIGN_IN_PRIVATE_KEY")
        assertInvalid(["APPLE_TEAM_ID": "T", "APPLE_SIGN_IN_KEY_ID": "K", "APPLE_SIGN_IN_PRIVATE_KEY": key], mentioning: "need APPLE_BUNDLE_ID too")
        assertInvalid(
            ["APPLE_BUNDLE_ID": "com.example.battleships", "APPLE_TEAM_ID": "T", "APPLE_SIGN_IN_KEY_ID": "K", "APPLE_SIGN_IN_PRIVATE_KEY": "not a key"],
            mentioning: "APPLE_SIGN_IN_PRIVATE_KEY must be the contents"
        )
        assertInvalid(["APPLE_BUNDLE_ID": "com example"], mentioning: "APPLE_BUNDLE_ID must be the app's bundle identifier")
        assertInvalid(["GOOGLE_IOS_CLIENT_ID": "com.googleusercontent.apps.1234-abc"], mentioning: "GOOGLE_IOS_CLIENT_ID must be the iOS client ID")
    }

    func testTheServerRefusesToStartWithInvalidSettings() async throws {
        setenv("MAX_OPEN_GAMES", "none", 1)
        defer { unsetenv("MAX_OPEN_GAMES") }
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            XCTFail("configure should have failed")
        } catch let error as ConfigurationError {
            XCTAssertTrue(error.reason.hasPrefix("MAX_OPEN_GAMES must be a whole number"))
        }
        try await app.asyncShutdown()
    }
}
