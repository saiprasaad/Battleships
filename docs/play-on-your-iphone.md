# Play it on your iPhone

There are two ways to get Battleships onto your own phone:

| | You need | Cost | Good for |
| --- | --- | --- | --- |
| **[Run it from Xcode](#run-it-from-xcode)** | A Mac with Xcode 16 or later (26 recommended), a USB cable | Free (any Apple ID) | Trying it out today |
| **[TestFlight](#no-mac-use-testflight)** | An Apple Developer Program membership | $99 a year | No Mac, or sharing it with friends |

Games against the computer work entirely on the phone. Online games also need the game server
running somewhere your phone can reach.

## Run it from Xcode

1. **Get the code** (the app lives on this branch until it's merged):

   ```sh
   git clone https://github.com/saiprasaad/Battleships.git
   cd Battleships
   git checkout claude/compassionate-dirac-xtlf8m
   open iOSApp/Battleships.xcodeproj
   ```

2. **Sign it with your Apple ID.** In Xcode, select the **Battleships** project, then the
   **Battleships** target, then **Signing & Capabilities**. Under *Team*, choose **Add an
   Account…**, sign in with your Apple ID, and pick your **(Personal Team)**. A free Apple ID is
   enough.

   If Xcode says the bundle identifier isn't available, change *Bundle Identifier* to something of
   your own, such as `com.yourname.battleships`.

3. **Connect your iPhone** with a cable, unlock it and tap **Trust**. The first time, turn on
   **Settings → Privacy & Security → Developer Mode** on the phone (it restarts).

4. In Xcode's toolbar, choose your iPhone as the run destination and press **Run** (⌘R). The first
   build takes a few minutes.

5. **With a free Apple ID**, iOS asks you to trust the developer the first time: open **Settings →
   General → VPN & Device Management**, tap your Apple ID and choose **Trust**. Apps signed this
   way stop opening after 7 days; press Run again to refresh it.

That's it: start a **New Battle → Computer** and play.

### Play online from your phone

Online games (random opponents, challenging friends, the leaderboard) need the server. To run it
on your Mac:

```sh
swift run --package-path Server BattleshipServer serve --hostname 0.0.0.0
```

The first build takes a few minutes. Then, on the phone (on the same Wi-Fi as the Mac):

1. Find your Mac's local name in **System Settings → General → Sharing** (at the bottom, e.g.
   `Sais-MacBook-Pro.local`).
2. In the app, open **Profile → Settings → Server**, enter `http://Sais-MacBook-Pro.local:8080`,
   tap **Test Connection**, then **Save**. Allow local network access when iOS asks.
3. Create an account and play. To try a two-player game on your own, run the app in the iPhone
   Simulator too (it can use `http://localhost:8080`), sign in as a second player there, and
   challenge one account from the other.

Once the server is deployed (see [Deploying the server](../README.md#deploying-the-server)), point
the app at its `https://` address instead and you can play from anywhere. Plain `http://` addresses
only work for servers on your local network.

**Sign in with Apple and Google** appear only when the server is set up for them (see
[Sign in with Apple and Google](sign-in.md)). Google works on any build. Sign in with Apple needs a
paid developer team: with a free Personal Team the Apple button shows an error, so use Google or a
username and password instead.

## No Mac? Use TestFlight

Apple doesn't allow installing your own apps on an iPhone without either Xcode or TestFlight, and
TestFlight needs an [Apple Developer Program](https://developer.apple.com/programs/) membership.
You don't need a Mac for it, though: this repository's **TestFlight** GitHub Actions workflow builds
and uploads the app on GitHub's Macs. Follow [docs/testflight.md](testflight.md) to set it up, then
install the **TestFlight** app from the App Store on your iPhone and accept the invitation.
