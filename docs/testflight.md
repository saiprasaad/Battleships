# Shipping builds to TestFlight

The **TestFlight** GitHub Actions workflow (`.github/workflows/testflight.yml`) builds a signed
Release version of the app on GitHub's Macs and uploads it to App Store Connect. You don't need a
Mac yourself. After a one-time setup, every run (or every `v*` tag you push) delivers a new build
to your testers.

Just want it on your own phone today and have a Mac? [Run it from Xcode](play-on-your-iphone.md)
instead; it's free and takes a few minutes.

## What you need

- An [Apple Developer Program](https://developer.apple.com/programs/) membership (TestFlight
  isn't available to free Apple IDs).
- The game server deployed at an `https://` address (see
  [Deploying the server](../README.md#deploying-the-server)). Without one, testers can still play
  the computer but not each other.

## One-time setup

### 1. Register the app's bundle ID

On [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) → **Certificates,
Identifiers & Profiles → Identifiers → +**, register an **App ID**:

- **Bundle ID**: Explicit, `com.saiprasaad.Battleships` (or your own; the workflow takes it from the
  provisioning profile).
- **Capabilities**: tick **Sign in with Apple** (*Enable as a primary App ID*), and **Push
  Notifications** if you want turn notifications. The workflow reads the capabilities from the
  provisioning profile and signs the app with them. The server needs its own keys for both: see
  [Sign in with Apple and Google](sign-in.md) and the README's APNs section.

### 2. Create the app in App Store Connect

[App Store Connect](https://appstoreconnect.apple.com/apps) → **Apps → + → New App**: platform iOS,
the bundle ID from step 1, any SKU (e.g. `battleships-ios`). The **name must be unique on the App
Store**, and plain "Battleships" is taken, so pick something like *Battleships: Fleet Command*. The
name under the icon on the home screen stays "Battleships".

### 3. Make an Apple Distribution certificate (.p12)

**On a Mac**: Xcode → **Settings → Accounts →** your team → **Manage Certificates → + → Apple
Distribution**. Then in **Keychain Access → My Certificates**, right-click *Apple Distribution: …*,
choose **Export**, save it as a `.p12` and set a password.

**Without a Mac** (any machine with OpenSSL):

```sh
openssl genrsa -out distribution.key 2048
openssl req -new -key distribution.key -out distribution.csr -subj "/CN=Your Name/C=GB"
```

Upload `distribution.csr` under **Certificates → + → Apple Distribution**, download the
`distribution.cer` it gives you, then bundle the two:

```sh
openssl x509 -inform DER -in distribution.cer -out distribution.pem
openssl pkcs12 -export -legacy -inkey distribution.key -in distribution.pem \
  -out distribution.p12 -passout pass:choose-a-password
```

(Drop `-legacy` if your OpenSSL is older than 3.0 and doesn't recognise it.) Keep `distribution.key`
and the `.p12` safe; they can sign apps as you.

### 4. Make an App Store provisioning profile

**Profiles → + → Distribution → App Store Connect**, choose the App ID from step 1 and the
certificate from step 3, give it a name such as *Battleships App Store*, and download the
`.mobileprovision` file. If you later change the App ID's capabilities, make a new profile.

### 5. Create an App Store Connect API key

App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
Name it *GitHub Actions* and give it the **App Manager** role. Download the `.p8` file (you can only
do this once) and note the **Key ID** and the **Issuer ID** shown above the list.

### 6. Add the secrets and variables to GitHub

In the repository: **Settings → Secrets and variables → Actions**.

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | The `.p12`, base64-encoded: `base64 -i distribution.p12` (macOS) or `base64 -w0 distribution.p12` (Linux) |
| `P12_PASSWORD` | The password you set on the `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | The `.mobileprovision`, base64-encoded the same way |
| `APP_STORE_CONNECT_KEY_ID` | The API key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The contents of the `.p8` file (paste it as is) |

| Variable | Value |
| --- | --- |
| `API_BASE_URL` | Your server, e.g. `https://battleships.fly.dev`. Release builds talk to it by default. |
| `BUILD_NUMBER_OFFSET` | Optional. Added to the workflow's run number to make the build number; raise it if App Store Connect says a build number is already used. |

With the [GitHub CLI](https://cli.github.com) that's, for example:

```sh
base64 -i distribution.p12 | gh secret set BUILD_CERTIFICATE_BASE64
gh secret set P12_PASSWORD --body 'choose-a-password'
base64 -i "Battleships App Store.mobileprovision" | gh secret set BUILD_PROVISION_PROFILE_BASE64
gh secret set APP_STORE_CONNECT_KEY_ID --body 'ABC123DEFG'
gh secret set APP_STORE_CONNECT_ISSUER_ID --body '00000000-0000-0000-0000-000000000000'
gh secret set APP_STORE_CONNECT_PRIVATE_KEY < AuthKey_ABC123DEFG.p8
gh variable set API_BASE_URL --body 'https://battleships.example.com'
```

## Upload a build

Either:

- **Push a version tag**: `git tag v1.0.0 && git push origin v1.0.0`. The tag sets the version
  (1.0.0); the build number comes from the workflow run.
- **Run it by hand**: **Actions → TestFlight → Run workflow**. GitHub only offers this button once
  the workflow file is on the default branch, so merge this branch first. It uses the version in
  the project (`MARKETING_VERSION`, currently 1.0).

The run takes about 15 minutes. Apple then processes the build (usually 5–30 minutes) and emails
you when it's ready.

## Invite testers

1. **Install TestFlight** from the App Store on each iPhone.
2. **Internal testers** (people on your App Store Connect team, up to 100): **TestFlight →
   Internal Testing → +**, create a group, add yourself, and turn on *automatic distribution* so new
   builds arrive by themselves. No review needed.
3. **External testers** (anyone with an email address or a public link, up to 10,000): create an
   external group. The first build of each version goes through a short **Beta App Review**, so fill
   in **TestFlight → Test Information** first:
   - *Beta App Description* and *Feedback Email*.
   - *Privacy Policy URL*: `https://<your server>/privacy` (the server publishes it).
   - *Sign-in required*: give the reviewer a demo account on your server (create one in the app),
     and mention that games against the computer need no account.
4. For each build, add **What to Test** notes so testers know what changed.

## Troubleshooting

| Message | Fix |
| --- | --- |
| *Missing secret …* | Add it under Settings → Secrets and variables → Actions (step 6). |
| *doesn't contain an Apple Distribution certificate with its private key* | Re-export the `.p12` from **My Certificates** (not *Certificates*) so the private key is included. |
| *development or ad hoc profile* | Make the profile under **Distribution → App Store Connect** (step 4). |
| *Provisioning profile … doesn't include signing certificate* | The profile was made with a different certificate. Edit it in the developer portal, select your current certificate, download it again and update `BUILD_PROVISION_PROFILE_BASE64`. |
| *The bundle version must be higher than the previously uploaded version* | Set `BUILD_NUMBER_OFFSET` (for example to `100`). |
| *The App ID doesn't have Sign in with Apple* (warning) | Enable the capability on the App ID (step 1), then make the profile again (step 4) and update `BUILD_PROVISION_PROFILE_BASE64`. |
| *This bundle is invalid… the version is closed for new builds* | The version was already released or approved; push a newer tag such as `v1.0.1`. |
| Upload fails with an authentication error | Check the Key ID and Issuer ID, that the whole `.p8` was pasted, and that the key has the App Manager role and hasn't been revoked. |

Every upload already answers the export-compliance question (the app only uses the encryption built
into iOS, declared in `Config/Info.plist`), so builds don't wait on it.

## Without GitHub Actions

On a Mac with Xcode, you can also upload by hand: choose your team under *Signing & Capabilities*,
select **Any iOS Device** as the destination, then **Product → Archive** and **Distribute App →
TestFlight & App Store**. Set `API_BASE_URL[config=Release]` in `iOSApp/Config/Battleships.xcconfig`
to your server first.
