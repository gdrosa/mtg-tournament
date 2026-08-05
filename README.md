# MTG Tournament

An organizer-first tournament manager for Magic: The Gathering events. One
Android phone owns the tournament and players join from any modern browser by
scanning a QR code. Each event can run fully online through a free Cloudflare
relay, or locally on the same Wi-Fi with no internet required during play.

<p align="center">
  <img src="docs/images/home.png" alt="MTG Tournament home screen" width="260" />
  <img src="docs/images/profile.png" alt="Player profile screen" width="260" />
</p>

> [!WARNING]
> LAN traffic uses plain HTTP/WebSocket and is intended for a trusted network.
> Never expose the phone's port `8080` to the public internet. Online mode uses
> HTTPS/WSS through the included relay instead.

## What it does

- Lets the organizer choose **Online** or **LAN** for every tournament.
- Hosts the authoritative tournament state directly on the organizer's Android phone.
- Lets players join a lightweight browser client by QR code, URL, or event code.
- Generates Swiss pairings and standings for best-of-three matches.
- Reconciles independent result submissions from both players.
- Reveals decklists after an accepted result and escalates reported infractions.
- Gives the organizer controls for disputes, drops, round advancement, and event closure.
- Stores player profiles, named decks, tournament history, and aggregate statistics locally.
- Resolves card names through Scryfall and caches images before offline play.
- Optionally backs up the app's JSON state to the user's private Google Drive app-data folder.
- Exports that state as one gzipped JSON file to any app (Files, Gmail, Telegram, WhatsApp) from Profile.
- Lets the owner set a deck profile picture from the clipboard or the device gallery.
- Keeps hosting alive through an Android foreground service while the screen is locked.

## How it works

The Flutter app owns the authoritative tournament state. In LAN mode it starts
an embedded `shelf` HTTP/WebSocket server on `0.0.0.0:8080`. In Online mode it
opens an outbound secure WebSocket to a Cloudflare Durable Object that relays
the same player commands and viewer-specific snapshots. State is persisted as
JSON on the host device after every mutation.

```text
Organizer Android app
  ├─ Flutter host UI
  ├─ tournament engine + JSON persistence
  ├─ LAN: embedded HTTP/WebSocket server → same-Wi-Fi browsers
  └─ Online: outbound WSS → Cloudflare relay → internet browsers
```

See [Architecture](docs/ARCHITECTURE.md) for the module boundaries, data flow,
trust model, and current limitations. The fuller product specification lives in
[Requirements](docs/REQUIREMENTS.md).

## Development setup

### Prerequisites

- Flutter `3.44.2` with Dart `3.12.2`
- Android Studio or the Android SDK command-line tools
- JDK 17
- An Android device or emulator for the host UI
- Node.js 22+ when developing or deploying the optional online relay

Check the local toolchain, fetch packages, and validate the project:

```shell
flutter --version
flutter doctor
flutter pub get
dart format --output=none --set-exit-if-changed lib test bin tool
flutter analyze
flutter test
```

Validate the optional online relay separately:

```shell
cd cloudflare
npm ci
npm run check
```

Run the Android host app:

```shell
flutter devices
flutter run -d <device-id>
```

For LAN events, the host and players must be on the same Wi-Fi. Some guest,
corporate, and public networks isolate clients; use a private router or hotspot
if players cannot reach the displayed URL.

### Optional free online relay

Online mode needs a free Cloudflare deployment and a build configured with its
public URL. Follow [Online hosting setup](docs/ONLINE_HOSTING.md). No Cloudflare
secret is committed to the app; Wrangler authentication stays on the developer
machine.

### Player-client development

The player interface has no JavaScript build step. Run the same Dart server used
by the app and open the printed URL:

```shell
dart run bin/dev_server.dart 8091
```

Edit `assets/web/app.js`, `assets/web/style.css`, or
`assets/web/index.html`, then refresh the browser.

### Android builds

For a locally installable debug APK:

```shell
flutter build apk --debug
```

Production APKs must use a private release keystore. Configure
`android/key.properties` and keep both that file and the keystore outside Git,
then run:

```shell
flutter build apk --release
```

The output is written below `build/app/outputs/flutter-apk/`.

### Optional Google Drive backup

Guest mode works without Google configuration. To enable account backup for a
signed build, register an Android OAuth client for package
`com.giuseppe.mtg.mtg_tourney` and each certificate that signs the app, enable
the Drive API, and configure the OAuth consent audience. The requested Drive
scope is limited to the app's private `appDataFolder`.

Follow [Google sign-in and Drive backup setup](docs/GOOGLE_SIGN_IN.md) for the
current release/debug fingerprints, consent-screen configuration, Play App
Signing guidance, and troubleshooting. Never commit account passwords or OAuth
client secrets.

## Repository layout

| Path | Purpose |
| --- | --- |
| `lib/shared/` | Models, Swiss pairing, tournament state machine, and statistics |
| `lib/server/` | REST/WebSocket server, snapshots, and JSON persistence |
| `lib/host/` | LAN/online lifecycle, relay client, foreground service, and orchestration |
| `lib/services/` | Scryfall cache and optional Google Drive integration |
| `lib/ui/` | Flutter organizer screens |
| `assets/web/` | No-build browser client shared by LAN and Online modes |
| `cloudflare/` | Free online relay Worker, Durable Object, and relay tests |
| `bin/` | Standalone development server |
| `test/` | Unit, persistence, and in-memory HTTP regression tests |
| `docs/` | Architecture, requirements, and curated screenshots |

## Data and security

- Tournament data is stored on the organizer's device, not in the online relay.
- Optional cloud backup writes one JSON blob to the user's private Drive app-data folder.
- Online traffic uses HTTPS/WSS; LAN mode still assumes a trusted network.
- Card lookup and host-side caching require internet during deck preparation.
  LAN events serve those cached images locally; Online player browsers load
  revealed card images directly from Scryfall and therefore require internet.
- Local captures, credentials, signing material, build output, and interview
  artifacts are excluded by `.gitignore`.

Security concerns should be reported according to [SECURITY.md](SECURITY.md),
without including live tokens or private tournament data in a public issue.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing the tournament engine or
wire protocol. Every change should keep `dart format`, `flutter analyze`, and
`flutter test` green. Relay or player-client changes must also keep the
Cloudflare type-check, tests, browser syntax check, and deploy dry run green;
GitHub Actions enforces both validation jobs.

## Credits

- Antonio Rossi

## Disclaimer

Magic: The Gathering is a trademark of Wizards of the Coast. This community
project is not affiliated with or endorsed by Wizards of the Coast. Card data
and images are retrieved from Scryfall when the organizer requests them.
