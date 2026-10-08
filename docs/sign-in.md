# Sign in with Apple and Google

Players can sign in three ways: **Continue with Apple**, **Continue with Google**, or a username
and password. Apple and Google only tell Battleships *which* account it is. The app asks for no
name, email or photo, and the player picks a username the first time.

The buttons appear only when the game server is set up for them. Google appears only alongside
Apple, because App Store guideline 4.8 requires Sign in with Apple in any app that offers another
company's sign-in.

## How it works

- **Apple**
  1. The app shows Apple's standard sign-in sheet and sends the server the identity token Apple
     returns, plus a one-time code.
  2. The server checks the token against Apple's public keys, including that it was issued for this
     app and this sign-in (a nonce).
  3. It exchanges the code for a refresh token. That token is kept only so the server can revoke
     the app's access when the player deletes their account, as Apple requires.
- **Google**
  1. The app opens Google's sign-in page in the system's secure sign-in sheet. There's no Google
     SDK in the app; the flow uses PKCE and asks only for the `openid` scope.
  2. The server checks the resulting ID token against Google's public keys.
- **The first time** an Apple or Google account is used, the server returns a sign-up ticket that
  is valid for 30 minutes. The app asks for a username and then creates the account. After that,
  signing in is a single tap.
- **If the player stops using their Apple ID with the app** (Settings → Apple Account → Sign in with
  Apple), the app notices the next time it opens and signs out.

## Set up Sign in with Apple

You need an [Apple Developer Program](https://developer.apple.com/programs/) membership.

1. **Enable the capability.** In the developer portal, go to **Certificates, Identifiers & Profiles →
   Identifiers**, open the app's App ID (`com.saiprasaad.Battleships`), tick **Sign in with Apple**
   (*Enable as a primary App ID*) and save.
2. **Make a new provisioning profile.** Profiles carry the App ID's capabilities, so go to
   **Profiles**, edit the App Store profile, save it, download it again, and update the
   `BUILD_PROVISION_PROFILE_BASE64` secret (see [TestFlight](testflight.md#4-make-an-app-store-provisioning-profile)).
   The TestFlight workflow adds the Sign in with Apple entitlement whenever the profile allows it,
   and warns in its log when it doesn't.
3. **Create a Sign in with Apple key.** The server needs it to revoke access when an account is deleted.
   1. Go to **Keys → +**, name it *Battleships Sign in with Apple*, tick **Sign in with Apple**, then
      **Configure** and choose the App ID.
   2. Register the key and download the `.p8` file. You can only download it once.
   3. Note the **Key ID**, and your **Team ID** (shown under *Membership details*).
4. **Configure the server** with these environment variables:

   | Variable | Value |
   | --- | --- |
   | `APPLE_BUNDLE_ID` | `com.saiprasaad.Battleships`. Turns Sign in with Apple on. |
   | `APPLE_TEAM_ID` | Your Team ID |
   | `APPLE_SIGN_IN_KEY_ID` | The key's Key ID |
   | `APPLE_SIGN_IN_PRIVATE_KEY` | The contents of the `.p8` file. Line breaks may be written as `\n`. |

   On Fly.io, for example:
   `fly secrets set APPLE_SIGN_IN_PRIVATE_KEY="$(cat AuthKey_ABC123DEFG.p8)"`.

## Set up Sign in with Google

1. **Create a project.** In the [Google Cloud console](https://console.cloud.google.com), create a
   project, for example *Battleships*.
2. **Set up the consent screen.** Open **Google Auth Platform**, also listed as *APIs & Services →
   OAuth consent screen*.
   - **Branding**: app name *Battleships*, a support email, the home page `https://<your server>/`,
     the privacy policy `https://<your server>/privacy`, and your server's domain under
     *Authorized domains*.
   - **Audience**: *External*, then **Publish app** so anyone can sign in, not just test users.
   - The app only uses the `openid` scope, which is non-sensitive, so Google doesn't need to verify
     the app. It may ask you to verify your brand if you add a logo.
3. **Create the client.** Go to **Clients → Create client**, choose *iOS* as the application type,
   and enter the bundle ID `com.saiprasaad.Battleships`. Copy the **Client ID**; it ends in
   `.apps.googleusercontent.com`.
4. **Configure the server**: set `GOOGLE_IOS_CLIENT_ID` to that client ID.

The app gets the client ID from the server, so turning Google on or off doesn't need a new build.

## Trying it from Xcode

- **Google** works on any build, including one signed with a free Apple ID.
- **Apple** needs a paid team, because free Personal Teams can't use the capability; there the
  Apple button shows an error. With a paid team, add this line to `iOSApp/Config/Signing.xcconfig`:

  ```
  CODE_SIGN_ENTITLEMENTS = Config/Capabilities.entitlements
  ```

  That also turns on push notifications. Xcode registers both capabilities for the App ID when it
  signs.
- **A server on your Mac** needs the same environment variables as above, for example
  `APPLE_BUNDLE_ID=com.saiprasaad.Battleships swift run --package-path Server BattleshipServer serve`.

## For App Review and the privacy label

- Deleting an account in the app (**Profile → Delete Account**) revokes the app's Apple
  authorization, as Apple requires. The server logs it if Apple can't be reached.
- The App Store privacy label needs no new data types. The Apple or Google account identifier is
  a **User ID**, linked to the player and used for app functionality, alongside the username. See
  [App Store submission](app-store.md).
- Reviewers can sign in with their own Apple ID, or use the demo username and password from the
  review notes.
