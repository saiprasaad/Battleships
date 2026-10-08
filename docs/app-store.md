# Submitting to the App Store

Everything App Store Connect asks for, with answers for Battleships that you can copy and paste.
It assumes you've already shipped a build to TestFlight ([docs/testflight.md](testflight.md)); the
same build is the one you submit.

Placeholders look like `<your server>` (for example `battleships.fly.dev`) and
`<your support email>`. Apple's rules and pages quoted here were checked on 8 October 2026.

| Where in App Store Connect | What goes there | Section |
| --- | --- | --- |
| **App Information** (sidebar, under General) | Name, subtitle, category, content rights, age rating | [1](#1-app-information), [3](#3-age-rating) |
| **App Privacy** | Privacy policy URL and the "nutrition label" | [4](#4-app-privacy) |
| **Pricing and Availability** | Price (free) and countries | [7](#7-pricing-and-availability) |
| **iOS App → 1.0** (the version page) | Screenshots, promotional text, description, keywords, URLs, copyright, build, review information | [2](#2-the-version-page), [5](#5-screenshots), [6](#6-app-review-information) |

## 1. App Information

### Name (at most 30 characters)

The name must be unique on the App Store, and plain "Battleships" is taken. Pick one of these
(App Store Connect tells you straight away if a name is already in use):

| Name | Characters |
| --- | --- |
| **Battleships: Naval Duel** (recommended) | 23 |
| Battleships: Fleet Command | 26 |
| Battleships - Call Your Shots | 29 |

The name under the icon on the home screen stays "Battleships" whichever you choose.

> **Trademark note.** "BATTLESHIP" is a Hasbro trademark for its board game. Lots of App Store games
> use "Battleships" (the old pencil-and-paper name), and App Review rarely objects, but a rights
> holder can complain to Apple about a name. Keep "Battleship" out of your keywords, and never use
> Hasbro's logo or artwork. If you'd rather avoid the question entirely, a name like
> *Broadside: Naval Duel* works just as well with the keywords below.

### Subtitle (at most 30 characters)

```
Play friends or the computer
```

28 characters. Alternatives: `Naval strategy, online or solo` (30), `Sink their fleet before yours` (29).

### Category

| Field | Choice | Why |
| --- | --- | --- |
| Primary category | **Games** | It's a game. |
| Subcategories (up to two) | **Board**, then **Strategy** | Battleships is a classic board/pencil-and-paper game, and that's what people browse for. Strategy fits the hunt-and-deduce play and the Admiral opponent. It also matches the app's own declared category (`public.app-category.board-games`). |
| Secondary category | **Entertainment** (optional) | A second place to be found. Leave it empty if you prefer. |

### Content rights

*Does your app contain, show, or access third-party content?* **No.** Every image is drawn by the
app, the sounds are generated in code, and the only text from other people is the usernames
players choose for themselves.

### Other fields

- **Primary language**: English (U.K.) matches the app's spelling ("practise", "colours"). English
  (U.S.) is fine too.
- **License agreement**: Apple's standard EULA.
- **Privacy Policy URL**: set on the App Privacy page (section 4).

## 2. The version page

On the version page (sidebar → **iOS App → 1.0 Prepare for Submission**).

### Promotional text (at most 170 characters)

You can change this at any time without a new build.

```
Three computer admirals, ranked online battles and friend challenges. Deploy your fleet, call your shots and climb the leaderboard. No ads, no in-app purchases.
```

160 characters.

### Description (at most 4,000 characters)

1,922 characters. Before pasting, check the two lines marked in the table below against how your
server is set up: App Review rejects descriptions that promise features the app doesn't have
(guideline 2.3.1).

```
Hunt down the enemy fleet before it finds yours.

Battleships is the classic game of naval strategy, rebuilt for iPhone and iPad. Every class of ship is drawn in detail, shells explode or splash where they land, and a radar sweeps the sea while you plan your next shot.

PLAY THE COMPUTER, EVEN OFFLINE
Pick one of three computer admirals:
• Cadet fires blind. Good for learning the ropes.
• Captain hunts methodically and finishes off every ship it hits.
• Admiral works out where your ships could still be hiding and fires at the likeliest square.
Games against the computer need no account and no connection, and a battle is saved if you leave halfway through.

CHALLENGE OTHER CAPTAINS ONLINE
• Get matched with a random opponent, or challenge a friend by username.
• Play at your own pace. Each move has a generous time limit, and if your opponent lets theirs run out, you can claim the win.
• Get a notification when it's your turn, when someone challenges you and when a battle ends.
• Online battles are rated: win and your rating rises, lose and it falls, and beating a stronger captain earns you more.
• Climb the leaderboard and see how you rank against the top captains.

TWO WAYS TO PLAY
• Classic: a 10×10 sea with a carrier, battleship, cruiser, submarine and destroyer.
• Quick: a 5×5 sea with five single-square boats, the original Battleships rules.

DEPLOY YOUR FLEET
Drag a ship to move it, tap it to turn it, or shuffle for a random layout. Ships may touch but never overlap.

BUILT WITH CARE
• VoiceOver support throughout.
• Haptics and sound effects, each of which you can turn off.
• Respects Reduce Motion.
• Made for iPhone and iPad. On iPad you see both boards at once.
• No ads, no in-app purchases, no tracking.

Online play needs a free account. We never ask for your name, email address or phone number. You can block or report other players, and delete your account in the app at any time.
```

| Line | Keep it only if |
| --- | --- |
| "Get a notification when it's your turn…" | The server has its APNs key (`APNS_*` variables) and the App ID has Push Notifications. Otherwise delete the line. |
| "You can block or report other players…" | The build you submit has Report and Block (see the [checklist](#8-pre-submission-checklist)). |

### Keywords (at most 100 bytes)

Comma-separated, no spaces after the commas. Words already in the name or subtitle are left out,
because Apple searches those anyway. This list goes with the recommended name and subtitle; if you
pick another name, remove any keyword that's now in it.

```
sea,battle,warship,navy,ship,board,strategy,multiplayer,2 player,online,offline,pvp,fleet,admiral
```

97 bytes. Apple doesn't allow other apps' or companies' names here, so no "Hasbro" or
"Battleship".

### URLs and copyright

| Field | Value | Notes |
| --- | --- | --- |
| Support URL | `https://<your server>/support` | Served by the game server. It must show a way to contact you, so set `SUPPORT_EMAIL` on the server (section 8). |
| Marketing URL | `https://<your server>/` (optional) | The server's home page, which links to support and privacy. You can leave it empty. |
| Privacy Policy URL | `https://<your server>/privacy` | Entered on the App Privacy page. Also served by the game server. |
| Copyright | `2026 <your name or company>` | App Store Connect adds the © itself. |
| Version | `1.0` | Must match the build's version (the TestFlight workflow uses the tag, e.g. `v1.0.0` → 1.0.0, or `MARKETING_VERSION`). |

Then, under **Build**, choose the TestFlight build you've tested. For the first version, choose
**Manually release this version** under *App Store Version Release*, so you decide when it goes live.

### Export compliance

Nothing to do. `iOSApp/Config/Info.plist` sets `ITSAppUsesNonExemptEncryption` to `NO`, which
answers App Store Connect's encryption questions for every build, so builds never wait on them.
That's the right answer because the app's only encryption is what's built into iOS: HTTPS through
`URLSession`, plus Apple's sign-in and hashing APIs. Apple: *"the use of encryption that's built
into the operating system—for example, when your app makes HTTPS connections using URLSession—is
exempt from export documentation upload requirements."* If you ever add your own or a third-party
encryption library, revisit this.

## 3. Age rating

Apple replaced its age ratings in 2025: the tiers are now **4+, 9+, 13+, 16+ and 18+**, and the
questionnaire gained sections on in-app controls, capabilities, medical topics and violence. Fill it
in under **App Information → Age Ratings → Set Up Age Ratings** (or **Edit**). Most questions are
answered *None / Infrequent / Frequent*; a few are *Yes / No*.

| Section | Question | Answer | Why |
| --- | --- | --- | --- |
| In-App Controls | Parental Controls | No | The app has none. |
| | Age Assurance | No | It doesn't check ages. |
| Capabilities | Unrestricted Web Access | No | No browser. Links open Safari, and Google sign-in shows only Google's sign-in page. |
| | User-Generated Content | **Yes** | Usernames are shown to other players (leaderboard, search, opponents). They're the only user content, and they're filtered, reportable and blockable (guideline 1.2). This doesn't raise the rating. |
| | Social Media | No | No feeds, likes, comments or sharing. |
| | Messaging and Chat | No | Players can't send each other messages. |
| | Advertising | No | No ads. |
| Mature Themes | Profanity or Crude Humor | None | The username filter rejects profanity, and the app's own text has none. |
| | Horror/Fear Themes | None | |
| | Alcohol, Tobacco, or Drug Use or References | None | |
| Medical or Wellness | Medical or Treatment Information | None | |
| | Health or Wellness Topics | No | |
| Sexuality or Nudity | Mature or Suggestive Themes | None | It's an abstract naval board game, not a story about real war or politics. |
| | Sexual Content or Nudity | None | |
| | Graphic Sexual Content and Nudity | None | |
| Violence | Cartoon or Fantasy Violence | **Infrequent** | Shells explode on drawn warships and a ship sinks in the defeat screen. No people are shown and nothing is gory, so it's mild. *Judgement call*: answering None (treating it as a pure board game) gives 4+. |
| | Realistic Violence | None | |
| | Prolonged Graphic or Sadistic Realistic Violence | None | |
| | Guns or Other Weapons | **Infrequent** | The warships carry gun turrets and you "fire" shells. *Judgement call*, as above. |
| Chance-Based Activities | Simulated Gambling | None | |
| | Contests | **Infrequent** | Online games change an Elo rating shown on a leaderboard, but there are no tournaments, events or prizes. *Judgement call*: Apple defines contests as "events that allow users to compete with one another for rankings"; if you read ranked play as frequent contests, the rating becomes 13+. |
| | Gambling | No | |
| | Loot Boxes | No | No purchases at all. |
| Additional Information | Age Category and Override | Not Applicable | Not a Kids-category app (it has online play with strangers). |
| | Age Suitability URL | Leave empty | |

**Resulting rating: 9+** (from the infrequent cartoon violence and weapons; everything else allows 4+).

If you'd rather keep under-13s out of online play, which is what the privacy policy's "not directed
at children under 13" implies, choose **Override to Higher Age Rating → 13+** on the last screen.
That's a choice, not a requirement.

## 4. App Privacy

Sidebar → **App Privacy**. Set the **Privacy Policy URL** to `https://<your server>/privacy`
(optionally the **Privacy Choices URL** too, to the same page), then **Get Started**.

### What "collect" means

Apple: *"'Collect' refers to transmitting data off the device in a way that allows you and/or your
third-party partners to access it for a period longer than what is necessary to service the
transmitted request in real time."* So:

- Games against the computer, settings and everything else kept only on the phone are **not**
  collected.
- Anything the game server stores (accounts, online games, push tokens, reports) **is** collected,
  even though it's only used to run the game.
- Data that passes through a request and isn't kept (for example an IP address used for a moment
  to rate-limit sign-ins) is not collected.

The app has no third-party SDKs (Sign in with Google is done with Apple's own web sign-in sheet,
not Google's SDK), so only your own server counts.

### The answers

Choose **Yes, we collect data from this app**, tick these four data types, then answer for each:

| Data type (as App Store Connect names it) | Linked to the user? | Used for tracking? | Purposes | What it is |
| --- | --- | --- | --- | --- |
| **Identifiers → User ID** | Yes | No | App Functionality | The username and account ID, used to sign in, match players, send challenges and show the leaderboard. With Sign in with Apple or Google, the server also stores that service's account identifier (never a name or email). |
| **User Content → Gameplay Content** | Yes | No | App Functionality | Online games (both fleets, every shot, the result), rating, wins and losses, and the players you've blocked, which steer matchmaking. Apple names "multiplayer matching" as gameplay content. |
| **Identifiers → Device ID** | Yes | No | App Functionality | The Apple push token, sent only if the player allows notifications, kept with the account to deliver "your turn" alerts. *Judgement call*: Apple doesn't say whether a push token is a "device ID"; declaring it is the cautious choice and adds nothing new to the label's summary. If your builds don't have the Push Notifications capability, the app never gets a token, so leave this out. |
| **User Content → Other User Content** | Yes | No | App Functionality | Reports: the reason a player chose and the game it was about, kept so you can moderate. *Judgement call*: reports could arguably be left out under Apple's "optional disclosure" rule for occasional, user-initiated submissions, but that rule also needs the reporter's account name shown on the form, which the app doesn't do, so declare it. |

Everything else is **not collected**: contact info (no name, email or phone), health, financial
info, location, sensitive info, contacts, emails or messages, photos, audio, customer support,
browsing history, search history (player searches aren't stored), purchases, usage data,
diagnostics, surroundings and body data.

Two more things that aren't on the label:

- **Passwords and session tokens.** They aren't one of Apple's data types; they're credentials, and
  the server only keeps one-way hashes of them.
- **IP addresses.** The server only holds them in memory for a short time to slow down repeated
  sign-in attempts, and doesn't store them with accounts, so under Apple's definition they aren't
  collected. *Judgement call*: if your hosting provider keeps access logs with IP addresses for a
  while and you use them (say, to investigate abuse), you could add **Diagnostics → Other
  Diagnostic Data**, linked, for App Functionality. The privacy policy already mentions logs.

With these answers the product page shows **Data Linked to You: Identifiers, User Content** and no
"Data Used to Track You". Click **Publish** when done.

**No tracking, so no App Tracking Transparency prompt.** The app doesn't link its data with other
companies' data for advertising, shares nothing with data brokers, has no ad SDKs and never reads
the advertising identifier, so it must not show the ATT permission prompt. The app's privacy
manifest (`iOSApp/Battleships/Resources/PrivacyInfo.xcprivacy`) also declares no tracking.

## 5. Screenshots

### What Apple requires

From Apple's [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications):
1 to 10 screenshots per display size, PNG or JPEG, **no transparency or alpha channel**, at one of
the listed pixel sizes. Because Battleships runs on iPad, **iPad screenshots are required too**.

| App Store Connect display | Required? | Accepted portrait sizes (pixels) | Folder in the artifact | Simulator used |
| --- | --- | --- | --- | --- |
| iPhone 6.9" (Dynamic Island, large display) | Upload it (see note) | 1320 × 2868, 1290 × 2796, 1260 × 2736 | `iphone-6.9in` | iPhone 17 Pro Max |
| iPhone 6.3" (Dynamic Island, medium display) | **Required** | 1206 × 2622, 1179 × 2556 | `iphone-6.3in` | iPhone 17 Pro |
| iPad 13" | **Required** (the app runs on iPad) | 2064 × 2752, 2048 × 2732 | `ipad-13in` | iPad Pro 13-inch (M5) |

Note: Apple's page currently lists the 6.3-inch iPhone set as the required one, but the same page
also says a 6.5-inch set is needed unless you provide 6.9-inch ones. Uploading both the 6.9-inch
and the 6.3-inch sets satisfies either reading, and App Store Connect scales them down for the
smaller iPhones and iPads.

### Make them with the workflow

The **App Store screenshots** workflow (`.github/workflows/app-store-screenshots.yml`) does it all on
GitHub's Macs:

1. In the repository, open **Actions → App Store screenshots → Run workflow**, choose the branch and
   click **Run workflow**. (GitHub only shows that button once the workflow file is on the default
   branch.) It also runs by itself when you push a `v*` tag, alongside the TestFlight workflow.
2. Wait about 20–30 minutes. The run builds the app once, then for each display size boots a fresh
   simulator, runs the app's tests, and keeps the screens listed in the workflow.
3. Open the finished run. Its summary shows a table of the simulators and image sizes. Under
   **Artifacts**, download **app-store-screenshots** and unzip it. You get one folder per display
   size, with files named by display and screen, numbered in upload order:

   | File (after the display prefix) | Screen |
   | --- | --- |
   | `01-battle` | A battle against the computer: a ship sunk, another hit, a target locked |
   | `02-lobby` | The Battles tab: a challenge, games waiting on you, recent results |
   | `03-new-battle` | Choosing an opponent (computer, random, friend), difficulty and rules |
   | `04-deploy-fleet` | Arranging your fleet |
   | `05-victory` | The victory screen |
   | `06-leaderboard` | The leaderboard, with your own rank highlighted |
   | `07-challenge` | A friend's challenge waiting for an answer |
   | `08-quick-battle` | A battle with the 5×5 rules |

   The first three are what people see in search results, so they matter most. Use all eight or
   stop at six.

The workflow checks every image with `sips` and fails, uploading nothing, if one has the wrong pixel
size or an alpha channel. If a run fails, the **app-store-screenshots-debug** artifact has every
rendered screen and the test results. The screens come from the app's screenshot test
(`iOSApp/BattleshipsTests/ScreenshotTests.swift`), which draws the real app with sample data. That
test draws only the app's own window, so the images have no status bar (no clock or battery);
that's fine for the App Store. The sample players (nemo, ahab, hornblower and so on) are fictional,
as Apple asks (guideline 2.3.9). To use different screens, edit `APP_STORE_SCENES` at the top of the
workflow.

### Upload them

1. Go to the version page → **Product Page Information** → **App Previews and Screenshots**.
2. Select the **iPhone** tab. Drag all the files from `iphone-6.9in` into the 6.9-inch slot and
   those from `iphone-6.3in` into the 6.3-inch slot. If the tab shows only one size, **View All
   Sizes in Media Manager** (on the right) lists the others.
3. Select the **iPad** tab and drag in the files from `ipad-13in` (13-inch).
4. Check the order (drag to reorder) and click **Save**.

## 6. App Review information

At the bottom of the version page.

### Sign-in information and demo accounts

Online play needs an account, so tick **Sign-in required** and give App Review a working account on
your **production** server. Make two, so a reviewer can try a whole online battle on their own:

| Account | Use | Where it goes |
| --- | --- | --- |
| `review_captain` | The reviewer signs in with it | **User name** and **Password** fields |
| `review_rival` | The opponent the reviewer challenges | In the review notes |

Use long random passwords (at least 8 characters), and a different one for each. Create the
accounts in the app (**Profile → Sign In or Create Account → Create Account**), or from any
terminal:

```sh
curl -fsS -X POST https://<your server>/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"review_captain","password":"<password 1>"}'
curl -fsS -X POST https://<your server>/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"review_rival","password":"<password 2>"}'
```

Sign in with both before every submission: reviewers sometimes delete demo accounts.

How the reviewer plays alone, which the notes below spell out for them:

1. Games against the computer need no account: **New Battle → Computer**.
2. Sign in as `review_captain` and send `review_rival` a challenge (**New Battle → Friend**).
3. Sign out, sign in as `review_rival`, open the challenge in the Battles tab and accept it.
4. The challenger fires first, so switch back to `review_captain` to shoot; after that, switch
   accounts each turn. (Or use two devices, one per account.)

### Contact information

| Field | Value |
| --- | --- |
| First and last name | `<your name>` |
| Phone number | `<your phone, with + and country code, e.g. +44 7700 900123>` |
| Email | `<your support email>` |

App Review uses these only to contact you.

### Notes (at most 4,000 bytes)

Replace the placeholders, then paste. About 2,500 bytes; with the optional last section, about 2,900.

```
Battleships is a turn-based naval strategy game for iPhone and iPad. Thank you for reviewing it.

GAMES AGAINST THE COMPUTER (no account needed, work offline)
Battles tab > New Battle > Computer > choose Cadet, Captain or Admiral > Next > Start Battle. Tap a square in Enemy Waters to aim, then tap it again (or press Fire) to shoot.

ONLINE PLAY
Accounts live on our game server, https://<your server>. Two demo accounts:
- review_captain / <password 1> (also in Sign-In Information)
- review_rival / <password 2>
Please don't delete these; to try Delete Account, create a new account first.

To play an online battle on one device:
1. Profile > Sign In or Create Account > sign in as review_captain.
2. Battles > New Battle > Friend > type review_rival > Next > Send Challenge.
3. Profile > Sign Out, then sign in as review_rival. In the Battles tab, open the challenge under Challenges, tap Accept, then Accept again to confirm the fleet.
4. The challenger fires first, so sign out and back in as review_captain to take the first shot. Turns alternate; switch accounts to play each side (or use two devices).
Random Opponent works too: choose it on one account, then on the other with the same rules, and the two are paired.

USER-GENERATED CONTENT (Guideline 1.2)
Usernames are the only user-generated content. There is no chat or messaging.
- Filter: usernames with offensive or reserved words are refused when an account is created.
- Report: in a battle or a challenge, tap ··· (top right) > Report and pick a reason. On the Leaderboard, touch and hold a player > Report. Reports come to us; we review them every day and remove offending accounts.
- Block: ··· > Block, or touch and hold a player on the Leaderboard. Blocked players can't challenge you and are never matched with you. Profile > Blocked Players lists them, with Unblock.
- Terms: signing in means agreeing to our Terms of Use (https://<your server>/terms, also under Profile > Terms of Use), which have zero tolerance for objectionable content and abusive players.
- Contact: our email address is on the support page, https://<your server>/support.

ACCOUNT DELETION (Guideline 5.1.1(v))
Profile > Delete Account deletes the account on the server immediately. Battles in progress are resigned.

PRIVACY
Profile > Privacy Policy opens https://<your server>/privacy. No ads, no analytics, no tracking. The app never asks for a name, email address or phone number.

NOTIFICATIONS
Optional. The app asks after you start your first online battle, so it can tell you when it's your turn. Everything works without them.

SERVER SETTING
Profile > Settings > Server is only for people who run their own game server. Please leave it at the default.
```

If the server has Sign in with Apple (and Google) turned on, add:

```

SIGN IN WITH APPLE AND GOOGLE
Continue with Apple is offered wherever Continue with Google is (Guideline 4.8). Neither shares a name or email address; the player picks a username the first time. You're welcome to use your own Apple ID instead of the demo accounts. Deleting an account that used Sign in with Apple also revokes the app's access to that Apple ID.
```

Only keep "we review them every day" if you will. Apple expects reports to be acted on within 24
hours. With `ADMIN_TOKEN` set on the server:

```sh
# Open reports, newest first
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://<your server>/v1/admin/reports
# Remove an offending player (exactly as if they'd deleted their account)
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://<your server>/v1/admin/players/<player id>
# Close a report you've dealt with
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" https://<your server>/v1/admin/reports/<report id>
```

The server also logs a warning ("Player reported") for every report.

## 7. Pricing and availability

Sidebar → **Pricing and Availability**.

- **Price**: Free. There are no in-app purchases.
- **Availability**: all countries, *except* **China mainland**, where games need a government
  approval number (App Store Connect will ask for it). Vietnam also licenses games; leave it out
  unless you've looked into it.
- **EU Digital Services Act**: App Store Connect asks once whether you're a "trader". A free
  hobby game without income usually isn't, but it's your call; if you are, your address and phone
  number appear on the EU product page.

## 8. Pre-submission checklist

### Server

- [ ] Deployed at a permanent `https://` address; `https://<your server>/health` answers. One
      instance, with a persistent volume or Postgres (see the README).
- [ ] `SUPPORT_EMAIL` set, so `/support`, `/privacy` and `/terms` show how to reach you
      (guidelines 1.2 and 1.5). Open all three pages in a browser to check.
- [ ] `ADMIN_TOKEN` set (16+ characters), so you can read and act on reports (see above).
- [ ] Behind a hosting proxy, `CLIENT_IP_HEADER` or `TRUSTED_PROXY_COUNT` set, so sign-in rate
      limits apply per player rather than to everyone at once.
- [ ] Push: either the `APNS_*` variables are set and the App ID has Push Notifications (then test a
      "your turn" notification on TestFlight), or the notification line is out of the description.
- [ ] Sign in with Apple (if offered): `APPLE_BUNDLE_ID`, `APPLE_TEAM_ID`, `APPLE_SIGN_IN_KEY_ID`
      and `APPLE_SIGN_IN_PRIVATE_KEY` set, and the App ID has the capability
      ([docs/sign-in.md](sign-in.md)). The key is what lets account deletion revoke Apple access.
- [ ] Sign in with Google (if offered): `GOOGLE_IOS_CLIENT_ID` set and the Google consent screen
      **published** ("In production"), or reviewers get "access blocked".
- [ ] Both demo accounts exist and sign in.
- [ ] The server stays up during review (Apple can take a day or two, at any hour). If it's down,
      the app is rejected under guideline 2.1.

### Build

- [ ] The `API_BASE_URL` repository variable pointed at the production server **before** the
      TestFlight build. (Without it the workflow stops; a build archived by hand in Xcode would
      fall back to the placeholder `https://battleships.example.com`.)
- [ ] Version and build number: tag `v1.0.0` (or use `MARKETING_VERSION` 1.0). Each upload needs a
      new build number; raise `BUILD_NUMBER_OFFSET` if App Store Connect refuses one.
- [ ] Tested the exact TestFlight build on an iPhone **and an iPad**: a game against the computer
      (also in airplane mode), creating an account, challenging and accepting, playing to the end,
      Report and Block, Profile → Blocked Players, Profile → Privacy Policy and Terms of Use, Delete Account (with a
      throwaway account), and Sign in with Apple/Google if offered. On iPad, try both orientations
      and Split View.
- [ ] What the review notes describe matches the build: ··· → Report / Block in a battle and a
      challenge, touch and hold on the leaderboard, Profile → Blocked Players, Profile → Privacy
      Policy. Edit the notes if anything moved.

### Listing

- [ ] Name, subtitle, category, content rights and age rating (sections 1 and 3).
- [ ] Privacy Policy URL and App Privacy answers published (section 4).
- [ ] Promotional text, description (checked against the server), keywords, support URL,
      copyright (section 2).
- [ ] Screenshots: 6.9-inch iPhone, 6.3-inch iPhone and 13-inch iPad (section 5).
- [ ] App Review information: sign-in details, contact, notes (section 6).
- [ ] Price and availability (section 7); build chosen; *Manually release this version*.
- [ ] Sign in with Apple: only needed because the app can offer Sign in with Google (guideline 4.8
      requires an equally private option next to any third-party login). The app never shows
      Google without Apple. If you don't set up Google, Sign in with Apple isn't required at all,
      because username-and-password accounts on your own server are exempt; offer it or not as
      you like.

### How the app meets the guidelines App Review checks most

| Guideline | What Apple wants | Battleships |
| --- | --- | --- |
| 2.1 App completeness | A final build, working URLs, a demo account and a running backend | Demo accounts and notes above; server checklist. |
| 2.3 Accurate metadata | Description and screenshots match the app | Screenshots are drawn from the app itself; check the two conditional description lines. |
| 4.8 Login services | If you offer a third-party login (Google), also offer an equivalent private one (Sign in with Apple) | The app shows Continue with Google only alongside Continue with Apple. With neither set up, the app only has its own username and password accounts, which need no alternative. |
| 5.1.1(i) Privacy policy | A link in App Store Connect **and inside the app** | `/privacy` on the server; Profile → Privacy Policy in the app. If you turn on Apple or Google sign-in, make sure the policy says the server stores that account's identifier. |
| 5.1.1(v) Account deletion | Apps that create accounts must let people delete them in the app | Profile → Delete Account. With Sign in with Apple, the server also revokes the app's Apple access. |
| 1.2 User-generated content | A filter, reporting with timely action, blocking, published contact details, and (App Review often asks) terms with zero tolerance for abuse that people agree to | Username filter (plus `BLOCKED_USERNAME_WORDS` on the server); Report; Block; `SUPPORT_EMAIL`; Terms of Use at `/terms`, which the sign-in screen says people agree to by continuing. |
| 5.1.2 Data use | No tracking without App Tracking Transparency | No tracking, no ads, no third-party SDKs. |
| 4.2 Minimum functionality | A real app, not a website | Native game with an offline mode. |

## After you submit

App Review usually answers within a day or two. If they reject the app, the message names the
guideline; reply in **App Review** in App Store Connect, or fix the problem and submit again. Once
approved, release it from the version page (if you chose manual release).

For later versions: push a new tag (say `v1.0.1`) to build for TestFlight and render new
screenshots, create the new version in App Store Connect, fill in **What's New in This Version**,
choose the build and submit.

### Accessibility labels (optional)

App Store Connect also has *Accessibility Nutrition Labels* (sidebar → **App Accessibility**). They're
voluntary for now, and you can only publish them once a version is live. Only claim what you've
tried on a device against Apple's criteria. Likely candidates for Battleships: **VoiceOver**,
**Dark Interface** (the app is always dark) and **Reduced Motion** (its looping animations stop).
Leave out **Larger Text** unless you've checked every screen at the largest sizes.
