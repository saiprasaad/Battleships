import Vapor

/// The public web pages: a home page, the privacy policy, support and the terms of use. App Store
/// Connect needs a privacy policy URL and a support URL, and the app links to all three.
struct SiteController: RouteCollection {
    let settings: ServerSettings

    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: home)
        routes.get("privacy", use: privacy)
        routes.get("support", use: support)
        routes.get("terms", use: terms)
    }

    @Sendable
    func home(req: Request) -> Response {
        page(SitePages.home())
    }

    @Sendable
    func privacy(req: Request) -> Response {
        page(SitePages.privacy(contact: settings.supportEmail))
    }

    @Sendable
    func support(req: Request) -> Response {
        page(SitePages.support(contact: settings.supportEmail))
    }

    @Sendable
    func terms(req: Request) -> Response {
        page(SitePages.terms(contact: settings.supportEmail))
    }

    private func page(_ html: String) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .html
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }
}

enum SitePages {
    static let lastUpdated = "8 October 2026"

    static func home() -> String {
        layout(title: "Battleships", body: """
        <h1>Battleships</h1>
        <p class="lead">Hunt down the enemy fleet before it finds yours. Play the computer, get matched \
        with another captain, or challenge a friend.</p>
        <p>This is the game server for the Battleships iPhone and iPad app.</p>
        <ul class="links">
          <li><a href="/support">Support</a></li>
          <li><a href="/privacy">Privacy Policy</a></li>
          <li><a href="/terms">Terms of Use</a></li>
        </ul>
        """)
    }

    static func privacy(contact: String?) -> String {
        layout(title: "Privacy Policy · Battleships", body: """
        <h1>Privacy Policy</h1>
        <p class="meta">Last updated \(lastUpdated)</p>
        <p class="lead">This explains what the Battleships app and its game server collect, why, and what \
        you can do about it. In short: very little, only to run the game, and you can delete it any time.</p>

        <h2>Games against the computer</h2>
        <p>They happen entirely on your device. Nothing about them is sent to us.</p>

        <h2>Your account</h2>
        <p>To play online you create an account. The server stores:</p>
        <ul>
          <li>your username;</li>
          <li>your password, if you chose one, only as a salted bcrypt hash, so nobody can read it;</li>
          <li>when you joined, and your rating, wins and losses;</li>
          <li>your signed-in sessions, as one-way hashes of their tokens.</li>
        </ul>
        <p>We don't ask for your name, email address, phone number, location or contacts.</p>

        <h2>Signing in with Apple or Google</h2>
        <p>If you sign in with Apple or Google, the server receives an identifier for your Apple or \
        Google account, not your name or email address, so it can recognise you next time. For Apple \
        it also receives a token, used only to revoke the app's access to your Apple ID when you \
        delete your account.</p>

        <h2>Your online games</h2>
        <p>The server keeps the games you play: both fleets, every shot, whose turn it is and the result. \
        Opponents see where their shots landed, and your ships once they're sunk or the game ends, but \
        never where the rest of your fleet is.</p>

        <h2>What other players see</h2>
        <p>Your username, rating, wins and losses appear on the leaderboard and in player search, and to \
        the players you challenge or are matched with.</p>

        <h2>Notifications</h2>
        <p>If you allow notifications, the app gives the server a push token from Apple so it can tell \
        you when it's your move. It's used for nothing else.</p>

        <h2>Blocking and reporting</h2>
        <p>If you block or report a player, the server records whom, the reason you chose and the game \
        it was about, so the people running the server can act on it.</p>

        <h2>Technical information</h2>
        <p>Like any web service, the server sees your IP address while you're connected. It's used to \
        slow down repeated sign-in attempts and may appear in server logs, which are kept briefly. \
        It isn't stored with your account.</p>

        <h2>What we never do</h2>
        <p>No advertising, no tracking across apps or websites, no analytics or third-party SDKs. We \
        don't sell or share your information with anyone.</p>

        <h2>Deleting your data</h2>
        <p>Your information is kept while you have an account. Delete it at any time in the app under \
        <strong>Profile → Delete Account</strong>. That removes your account, sessions, push tokens, \
        blocks, reports and the link to any Apple or Google account (and revokes the app's access to \
        your Apple ID); games in progress are resigned, and finished games stay in your opponents' \
        history without your username.</p>

        <h2>Children</h2>
        <p>Battleships isn't directed at children under 13, and we don't knowingly collect personal \
        information from them.</p>

        <h2>Changes and contact</h2>
        <p>If this policy changes, we'll update this page and the date at the top. \(contactSentence(contact))</p>
        <p>Using the game is also subject to the <a href="/terms">Terms of Use</a>.</p>
        """)
    }

    static func support(contact: String?) -> String {
        layout(title: "Support · Battleships", body: """
        <h1>Support</h1>
        <p class="lead">\(contactSentence(contact))</p>

        <h2>How do I play?</h2>
        <p>Deploy your fleet, then take turns firing at the enemy's waters: tap a square to aim, tap \
        again (or press Fire) to shoot. A splash is a miss, a flame is a hit, and a ship sinks when \
        every square of it is hit. Sink the whole enemy fleet to win. <strong>Profile → How to \
        Play</strong> has the details.</p>

        <h2>Do I need an account?</h2>
        <p>Only to play other people. Games against the computer work without one, even offline.</p>

        <h2>How do I report or block a player?</h2>
        <p>In a battle or a challenge, tap <strong>···</strong> and choose <strong>Report</strong> or \
        <strong>Block</strong>. On the leaderboard, touch and hold a player. Blocked players can't \
        challenge you and you won't be matched with them. Manage them under <strong>Profile → Blocked \
        Players</strong>.</p>

        <h2>I forgot my password</h2>
        <p>Battleships doesn't collect email addresses, so passwords can't be reset. You can create a \
        new account at any time.</p>

        <h2>How do I delete my account?</h2>
        <p>In the app, <strong>Profile → Delete Account</strong>. It's permanent. See the \
        <a href="/privacy">privacy policy</a> for what's removed.</p>

        <h2>My opponent stopped playing</h2>
        <p>Each move has a time limit. When your opponent runs out of time, the battle offers you \
        <strong>Claim Victory</strong>.</p>

        <h2>The rules for players</h2>
        <p>See the <a href="/terms">Terms of Use</a>.</p>
        """)
    }

    static func terms(contact: String?) -> String {
        layout(title: "Terms of Use · Battleships", body: """
        <h1>Terms of Use</h1>
        <p class="meta">Last updated \(lastUpdated)</p>
        <p class="lead">By playing Battleships online you agree to these terms. They're short, and \
        they come down to this: be decent to the other captains.</p>

        <h2>Who can play</h2>
        <p>You need to be old enough to agree to these terms where you live.</p>

        <h2>Your account</h2>
        <ul>
          <li>Keep your password safe. You're responsible for what happens with your account.</li>
          <li>Usernames must not be offensive, hateful or sexual, impersonate anyone, or contain \
          personal information.</li>
        </ul>

        <h2>Zero tolerance</h2>
        <p>There is zero tolerance for objectionable content and abusive players. No offensive \
        usernames, harassment, hate, threats, cheating, exploiting bugs or automated play.</p>
        <p>Reported players are reviewed, and accounts that break these rules can be removed without \
        notice.</p>
        <p>You can report or block anyone in the app: in a battle or a challenge, tap \
        <strong>···</strong> and choose <strong>Report</strong> or <strong>Block</strong>; on the \
        leaderboard, touch and hold a player. Blocked players can't challenge you and you won't be \
        matched with them. Manage them under <strong>Profile → Blocked Players</strong>.</p>

        <h2>Fair play and the service</h2>
        <p>The game is provided as is. It may change, and may sometimes be unavailable. Ratings can \
        be adjusted to undo the effects of cheating.</p>

        <h2>Deleting your account</h2>
        <p>You can delete your account at any time in the app under <strong>Profile → Delete \
        Account</strong>. The <a href="/privacy">privacy policy</a> explains what's removed.</p>

        <h2>Contact</h2>
        <p>\(contactSentence(contact))</p>
        """)
    }

    private static func contactSentence(_ contact: String?) -> String {
        guard let contact else {
            return "For questions or requests, contact the people who run this server."
        }
        let address = escaped(contact)
        return "For questions, problems or requests, email <a href=\"mailto:\(address)\">\(address)</a>."
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func layout(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="dark">
        <title>\(title)</title>
        <style>
          :root { --sea: #0b1f3d; --deep: #050d1c; --glow: #66ebff; --text: #e8eef6; --muted: #9fb0c4; }
          * { box-sizing: border-box; }
          body {
            margin: 0; color: var(--text); line-height: 1.6;
            font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: radial-gradient(ellipse at top, #12345e 0%, var(--sea) 45%, var(--deep) 100%) fixed;
            min-height: 100vh;
          }
          main { max-width: 42rem; margin: 0 auto; padding: 3rem 1.25rem 4rem; }
          h1 { font-size: 2.2rem; letter-spacing: 0.04em; margin: 0 0 0.25rem; text-shadow: 0 0 18px rgba(102, 235, 255, 0.35); }
          h2 { font-size: 1.15rem; margin: 2rem 0 0.4rem; color: var(--glow); }
          .lead { font-size: 1.1rem; }
          .meta, li::marker { color: var(--muted); }
          a { color: var(--glow); }
          .links { list-style: none; padding: 0; display: flex; gap: 1.5rem; }
          strong { color: #fff; }
        </style>
        </head>
        <body><main>
        \(body)
        </main></body>
        </html>
        """
    }
}
