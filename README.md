# Battleships

A native iOS Battleships game with its own backend, written in Swift end to end.

- **`iOSApp/`**: the SwiftUI app. Play the computer offline, get matched with a random opponent, or challenge a friend by username. Live updates, push notifications, a leaderboard, and full VoiceOver support. Battles are played on an animated sea: every class of ship is drawn in detail, shells explode or splash where they land, and the sound effects are synthesised in code.
- **`Server/`**: the backend, built from scratch on [Vapor](https://vapor.codes). Accounts, matchmaking, challenges, server-enforced rules, Elo ratings, WebSocket events and optional Apple push notifications. Runs on SQLite or Postgres.
- **`BattleshipKit/`**: a Swift package shared by both. It holds the game engine, the computer opponents, the JSON wire format and the networking client. Because the app and server compile against the same types, their API can't drift apart.

<p align="center">
  <img src="docs/screenshots/lobby.jpg" width="200" alt="The lobby: a radar sweeping the sea above your battles">
  <img src="docs/screenshots/battle.jpg" width="200" alt="A battle: aiming at enemy waters, with your own fleet in miniature">
  <img src="docs/screenshots/victory.jpg" width="200" alt="Victory, with a gold sunburst">
  <img src="docs/screenshots/deploy.jpg" width="200" alt="Deploying your fleet">
</p>
<p align="center">
  <img src="docs/screenshots/ipad.jpg" width="820" alt="A battle on iPad, with both boards side by side">
</p>

> The original Flutter client (`lib/`, `android/`, `ios/`, `web/`, …) is still at the repository root. It talks to the old CS 442 course server and isn't used by the new app.

## The game

| Mode | Board | Fleet |
| --- | --- | --- |
| **Classic** | 10×10 | Carrier (5), Battleship (4), Cruiser (3), Submarine (3), Destroyer (2) |
| **Quick** | 5×5 | Five single-cell patrol boats: the original Battleships rules |

Players alternate single shots. A ship sinks when every square of it has been hit, and its position is then revealed. Sink the whole enemy fleet to win. Ships may touch but not overlap. Online, each move has a time limit (three days by default); if a player lets it run out, their opponent can claim the win.

Online games change your Elo rating and win/loss record, except a battle that ends before both players have fired a shot (resigned straight away, abandoned by deleting the account, or won on time against someone who never moved): it doesn't count either way. Matchmaking pairs you with whoever has waited longest for the same mode, provided they joined the queue in the last 15 minutes or have had the app open since; anyone else stays queued until they're back, since the player who was waiting fires first.

Against the computer you choose a difficulty:

| Level | How it plays | Average shots to sink a classic fleet* |
| --- | --- | --- |
| Cadet | Fires at random | 96 |
| Captain | Hunts on a checkerboard; after a hit, works along the ship until it sinks | 51 |
| Admiral | Counts every position the remaining ships could still be in and fires at the likeliest square | 45 |

<sub>*Averaged over 2,000 simulated games. The test suite checks the ordering: `BattleshipKit/Tests/BattleshipCoreTests/ComputerOpponentTests.swift`.</sub>

## Running it

You need **Xcode 16 or later** (Xcode 26 recommended) for the app. The server and shared package also build on Linux with Swift 6.

### 1. Start the server

```sh
swift run --package-path Server BattleshipServer serve
# Server started on http://127.0.0.1:8080
```

This creates `battleships.sqlite` in the current directory. To use Docker instead:

```sh
docker compose -f Server/docker-compose.yml up --build
```

### 2. Run the app

1. Open `iOSApp/Battleships.xcodeproj`.
2. Pick the **Battleships** scheme and an iPhone simulator, then **Run**.

Debug builds talk to `http://localhost:8080`, which the simulator shares with your Mac. Games against the computer need no server at all.

**On a real iPhone** (step by step, including for a free Apple ID: [docs/play-on-your-iphone.md](docs/play-on-your-iphone.md)):

1. Select your team under *Signing & Capabilities*, and change the bundle identifier if Xcode asks.
2. Point the app at your Mac using its Bonjour name: *Profile → Settings → Server → `http://your-mac-name.local:8080`*.
3. Start the server listening on the network: `swift run --package-path Server BattleshipServer serve --hostname 0.0.0.0`.

Release builds default to the URL in `iOSApp/Config/Battleships.xcconfig` (`API_BASE_URL`). Set it to your deployed server, which must use HTTPS.

## Deploying the server

The server is a single binary (or a small Docker image) configured entirely with environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8080` | Port to listen on. Most hosting platforms set this for you. |
| `DATABASE_URL` | *unset* | A `postgres://` URL. When set, Postgres is used instead of SQLite. |
| `SQLITE_PATH` | `battleships.sqlite` | SQLite database file when `DATABASE_URL` isn't set. In Docker: `/app/data/battleships.sqlite` (a volume). |
| `LOG_LEVEL` | `info` | `trace`, `debug`, `info`, `notice`, `warning`, `error` or `critical`. |
| `CLIENT_IP_HEADER` | *unset* | Behind a proxy: a header the proxy sets to the player's IP address and clients can't forge, e.g. `Fly-Client-IP`. See [Behind a proxy](#behind-a-proxy). |
| `TRUSTED_PROXY_COUNT` | `0` | Behind proxies that append to `X-Forwarded-For`: how many there are. The address that many entries from the right is used. Set this or `CLIENT_IP_HEADER`, not both. |
| `AUTH_RATE_LIMIT_PER_MINUTE` | `20` | Sign-in and registration attempts allowed per IP address per minute. |
| `LOGIN_RATE_LIMIT_PER_USERNAME_PER_HOUR` | `10` | Sign-in attempts allowed per username per hour, however many addresses they come from. |
| `MAX_OPEN_GAMES` | `20` | Games a player can have in progress or waiting at once. |
| `NEW_GAME_RATE_LIMIT_PER_HOUR` | `30` | Games (challenges or matchmaking) a player can start per hour. |
| `MAX_PENDING_CHALLENGES` | `20` | Unanswered challenges a player can have waiting for them at once. |
| `TURN_TIME_LIMIT_HOURS` | `72` | How long a player has to move before their opponent can claim the win. More than 0, at most 8760. |
| `SUPPORT_EMAIL` | *unset* | Contact address shown on the `/privacy`, `/support` and `/terms` pages. App Review expects one. |
| `ADMIN_TOKEN` | *unset* | At least 16 characters (`openssl rand -hex 32`). Turns on the moderation endpoints under `/v1/admin`; see [Moderation](#moderation). |
| `BLOCKED_USERNAME_WORDS` | *unset* | Comma-separated words that new usernames can't contain, on top of the built-in list. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_PRIVATE_KEY` (or `APNS_PRIVATE_KEY_PATH`) | *unset* | Push notifications; see below. |
| `APPLE_BUNDLE_ID` | *unset* | The app's bundle identifier. Turns on Sign in with Apple; see [Sign in with Apple and Google](#sign-in-with-apple-and-google). |
| `APPLE_TEAM_ID`, `APPLE_SIGN_IN_KEY_ID`, `APPLE_SIGN_IN_PRIVATE_KEY` | *unset* | The Sign in with Apple key (the `.p8` file's contents; `\n` escapes are fine), so that deleting an account revokes the app's access to the player's Apple ID. Set all three or none. |
| `GOOGLE_IOS_CLIENT_ID` | *unset* | The OAuth client ID of a Google Cloud *iOS* client (it ends in `.apps.googleusercontent.com`). Turns on Sign in with Google. |

Database migrations run automatically on start-up. A setting with an invalid value (a `PORT` that isn't a number, a zero time limit, half the APNs variables…) stops the server at start-up with a message naming it, rather than being ignored.

**Docker on any server:**

```sh
docker build -f Server/Dockerfile -t battleships-server .     # from the repository root
docker run -d -p 8080:8080 -v battleships-data:/app/data battleships-server
```

**Fly.io, Render, Railway and similar** all build straight from `Server/Dockerfile` (set the build context to the repository root). Give the service a persistent volume mounted at `/app/data`, or attach a managed Postgres database and set `DATABASE_URL`. These platforms terminate HTTPS for you; on your own machine, put Caddy or nginx in front. Then set `CLIENT_IP_HEADER` or `TRUSTED_PROXY_COUNT` (next section).

The container starts as root only long enough to hand the data directory to the unprivileged `vapor` user (platform volumes usually belong to root, which would otherwise stop SQLite opening its file), then runs the server as `vapor`. The image has a Docker `HEALTHCHECK`, and `GET /health` returns 503 when the database doesn't answer or writes have stalled, so platforms that health-check it restart a server that's stuck.

The server keeps WebSocket connections in memory and serializes game moves within the process, so run **one instance**. That comfortably handles thousands of players.

### Behind a proxy

Rate limits are kept per IP address. By default the server uses the address of whatever connected to it, which can't be faked. Behind a hosting platform's load balancer that's the balancer, for every player, so they'd all share one allowance (the server logs a warning when it sees this). Tell it where the player's address is:

- **Fly.io:** `CLIENT_IP_HEADER=Fly-Client-IP`, the client address as Fly's proxy sees it ([Fly's request headers](https://docs.fly.io/networking/request-headers)).
- **Cloudflare** in front of the server: `CLIENT_IP_HEADER=CF-Connecting-IP`, as long as the server can only be reached through Cloudflare.
- **Railway:** its docs name `X-Real-IP` as the header its edge proxy sets ([specs and limits](https://docs.railway.com/networking/public-networking/specs-and-limits)), so `CLIENT_IP_HEADER=X-Real-IP`, but they don't promise clients can't forge it. Check Railway's current docs first.
- **Render:** Render doesn't document a header that clients can't forge. Check Render's docs or support before setting either option.
- **Your own nginx or Caddy:** `TRUSTED_PROXY_COUNT=1`. Both append the connecting address to `X-Forwarded-For` (with nginx, `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for`).

Never use a header that clients can set themselves, such as the first `X-Forwarded-For` entry: anyone could dodge the limits by sending a different address each time. Sign-ins are also limited per username, wherever they come from.

### Push notifications

Players get notified when it's their turn, when they're challenged, and when a game ends. To turn this on:

1. In your Apple Developer account, create an **APNs key** (*Certificates, Identifiers & Profiles → Keys*). Note the Key ID and your Team ID, and download the `.p8` file.
2. Give the server `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (the app's bundle identifier) and the key: either `APNS_PRIVATE_KEY` (the file's contents; `\n` escapes are fine) or `APNS_PRIVATE_KEY_PATH`.
3. In Xcode, add the **Push Notifications** capability to the Battleships target.

Push is off by default because free (personal team) developer accounts can't use it. Everything else works without it, and games still update live over WebSocket while the app is open.

A device gets notifications for the session that registered it: signing out (or the session expiring) stops them. Each player keeps at most 10 devices.

### Sign in with Apple and Google

Players can sign in with Apple or Google instead of a username and password. The first time, they pick a username; the app asks for neither their name nor their email address. If you offer Google, App Store guideline 4.8 requires Apple too (the server warns at start-up otherwise).

**Apple**

1. In your Apple Developer account (*Certificates, Identifiers & Profiles → Identifiers*), open the app's App ID and turn on the **Sign in with Apple** capability. TestFlight builds pick it up from the provisioning profile; to use it from Xcode with a paid team, see [docs/sign-in.md](docs/sign-in.md#trying-it-from-xcode). Free Personal Teams can't use it.
2. Under *Keys*, create a key with **Sign in with Apple** enabled, configured for the app's App ID as its primary App ID. Note the Key ID and download the `.p8` file (you can only download it once).
3. Set `APPLE_BUNDLE_ID` to the app's bundle identifier, `APPLE_TEAM_ID` to your Team ID (shown in the developer account under *Membership details*), `APPLE_SIGN_IN_KEY_ID` to the Key ID, and `APPLE_SIGN_IN_PRIVATE_KEY` to the contents of the `.p8` file.

The key lets the server exchange the app's authorization code for a refresh token, which it uses when an account is deleted to revoke the app's access to the player's Apple ID, as App Review requires. With `APPLE_BUNDLE_ID` alone, signing in works but nothing can be revoked, and the server logs an error at start-up in production.

**Google**

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project (or pick an existing one).
2. Set up the **OAuth consent screen**: user type *External*, the app's name, a support email, and `https://<your server>/privacy` as the privacy policy link. The app only asks for the `openid` scope, which doesn't need Google's verification.
3. Under **Credentials**, create an **OAuth client ID** of type **iOS**, with the app's bundle ID.
4. Copy the client ID (it ends in `.apps.googleusercontent.com`) into `GOOGLE_IOS_CLIENT_ID`. The app learns it from `GET /v1/auth/providers`.

### Moderation

Players can block and report each other in the app, and usernames are checked against a built-in list of slurs and reserved names (`admin`, `support`…). Add your own words with `BLOCKED_USERNAME_WORDS`. To review reports, set `ADMIN_TOKEN` and send it as a bearer token:

```sh
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://your-server/v1/admin/reports                     # open reports, newest first
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://your-server/v1/admin/reports/REPORT_ID  # dismiss one
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://your-server/v1/admin/players/PLAYER_ID  # delete an account
```

Without `ADMIN_TOKEN` these endpoints don't exist. Deleting an account through them works exactly like a player deleting their own.

## The API

All endpoints are JSON under `/v1`. Authenticated ones need `Authorization: Bearer <token>`. A session lasts 90 days and is renewed automatically while it's being used. Errors look like `{"code": "not_your_turn", "message": "It's not your turn."}`; too many requests get `429` with `rate_limited`. The Swift types for every request and response live in `BattleshipKit/Sources/BattleshipAPI`.

| Method | Path | |
| --- | --- | --- |
| `POST` | `/v1/auth/register` | Create an account → `{token, account}` |
| `POST` | `/v1/auth/login` | Sign in → `{token, account}` |
| `POST` | `/v1/auth/logout` | Revoke this session |
| `GET` | `/v1/auth/providers` | Whether the server offers Sign in with Apple and Google |
| `POST` | `/v1/auth/apple` | `{identityToken, authorizationCode?, nonce}` → `{session}`, or the first time `{signupTicket, suggestedUsername}` |
| `POST` | `/v1/auth/google` | `{idToken, nonce}` → the same |
| `POST` | `/v1/auth/complete-signup` | `{signupTicket, username}` → `{token, account}`: finish signing up with Apple or Google (tickets last 30 minutes and work once) |
| `GET` | `/v1/me` | Your account and stats |
| `DELETE` | `/v1/me` | Delete your account (battles in progress are resigned) |
| `GET` | `/v1/me/blocked` | Players you've blocked |
| `GET` | `/v1/players?prefix=` | Find players to challenge |
| `PUT` | `/v1/players/:id/block` | Block a player: no challenges or matchmaking between you, and unanswered challenges are withdrawn |
| `DELETE` | `/v1/players/:id/block` | Unblock them |
| `POST` | `/v1/players/:id/report` | `{reason, gameID?}`: report a player. Reporting the same player again updates your report |
| `GET` | `/v1/leaderboard` | Top 50 by rating |
| `GET` | `/v1/games` | Your unfinished games and recent results |
| `POST` | `/v1/games` | `{mode, fleet, opponent?}`: challenge `opponent` (one unanswered challenge between two players at a time), or join matchmaking |
| `GET` | `/v1/games/:id` | One game, from your side (enemy ships hidden until sunk) |
| `POST` | `/v1/games/:id/accept` | Accept a challenge with your fleet |
| `POST` | `/v1/games/:id/decline` | Decline a challenge |
| `POST` | `/v1/games/:id/cancel` | Withdraw a game that hasn't started |
| `POST` | `/v1/games/:id/shots` | `{target: "B7"}` → `{move, game}` |
| `POST` | `/v1/games/:id/resign` | Resign |
| `POST` | `/v1/games/:id/claim-victory` | Win a game whose opponent let their turn time run out |
| `POST` | `/v1/devices` | Register an APNs device token |
| `DELETE` | `/v1/devices/:token` | Unregister it |
| `GET` | `/v1/events` | WebSocket of `hello`, `gameUpdated` and `gameRemoved` events. Up to 5 per player; a connection that stops reading is closed |
| `GET` | `/v1/admin/reports` | Open reports, for `ADMIN_TOKEN` holders ([Moderation](#moderation)) |
| `DELETE` | `/v1/admin/reports/:id` | Dismiss a report |
| `DELETE` | `/v1/admin/players/:id` | Delete a player's account |
| `GET` | `/health` | `{"status":"ok"}`, or 503 when the database doesn't answer |
| `GET` | `/`, `/privacy`, `/support`, `/terms` | The home page, privacy policy, support page and terms of use (HTML), for App Store Connect and the app's links |

Coordinates are written like the board: a row letter and a column number, e.g. `"A1"` or `"J10"`.

## Development

```sh
swift test --package-path BattleshipKit    # engine, AI, wire format, client
swift test --package-path Server           # server, incl. end-to-end games through the app's client
TEST_DATABASE_URL=postgres://localhost/battleships_test swift test --package-path Server   # the same on Postgres (wipes that database)
xcodebuild test -project iOSApp/Battleships.xcodeproj -scheme Battleships \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

GitHub Actions runs all of this on every push (`.github/workflows/ci.yml`): the shared package and server tests on Linux and macOS, the server tests again on Postgres 16, the app's build and unit tests on an iOS simulator, and a Docker build of the server with a smoke test. The app job also renders the main screens to PNGs (`BattleshipsTests/ScreenshotTests.swift`) and uploads them as the `screenshots` artifact.

How the code is organised:

- **`BattleshipKit/Sources/BattleshipCore`**: rules, fleets, the `Battle` state machine (it replays and verifies stored moves), `BattlePerspective` (one player's redacted view, which both boards are drawn from), and the computer opponents.
- **`BattleshipKit/Sources/BattleshipAPI`** and **`BattleshipClient`**: the wire format, plus `APIClient` (REST) and `RealtimeClient` (WebSocket that reconnects with backoff).
- **`Server/Sources/BattleshipServer`**: `GameService` holds the game logic. Every write goes through one async lock, so two requests can't act on the same game or grab the same matchmaking opponent.
- **`iOSApp/Battleships/Model`**: app state with no UIKit or SwiftUI imports (stores, `BattleController`, fleet placement). It's unit tested in `iOSApp/BattleshipsTests`.
- **`iOSApp/Battleships/Views`**: SwiftUI. Ships, explosions and the sea are drawn with `Canvas`; looping effects run off a `TimelineView` and hold still when Reduce Motion is on. Liquid Glass is used on iOS 26, with materials as the fallback on iOS 17 and later.
- **`iOSApp/Battleships/Model/SoundSynthesis.swift`**: the sound effects, generated as samples at launch (so there are no audio files) and played through `AVAudioEngine` with the ambient session, which respects the silent switch.

To regenerate the app icon: `python3 iOSApp/Tools/make_app_icon.py iOSApp/Battleships/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (needs Pillow).

## Before submitting to the App Store

The guides in `docs/` walk through it:

- [docs/testflight.md](docs/testflight.md): sign and upload builds to TestFlight from GitHub Actions, no Mac needed.
- [docs/sign-in.md](docs/sign-in.md): set up Sign in with Apple and Google.
- [docs/app-store.md](docs/app-store.md): everything App Store Connect asks for, ready to paste (listing, age rating, privacy answers, screenshots, review notes), and a pre-submission checklist. The **App Store screenshots** workflow renders the screenshots at the sizes Apple requires.

In short:

- Set your bundle identifier, team and the release `API_BASE_URL` (HTTPS).
- Set `SUPPORT_EMAIL` on the server, and give App Store Connect `https://<server>/privacy` as the privacy policy URL and `https://<server>/support` as the support URL. The app links to the terms of use, `https://<server>/terms`, when players sign in.
- If you offer Sign in with Apple, set its key (above) so deleting an account revokes the app's access to the player's Apple ID.
- Set `ADMIN_TOKEN` so you can act on reports.
- Enable push (above) if you want it.
- Accounts can be deleted inside the app (*Profile → Delete Account*), as App Review requires.
- The app makes no tracking requests and uses only standard encryption (`ITSAppUsesNonExemptEncryption` is already `NO`).
