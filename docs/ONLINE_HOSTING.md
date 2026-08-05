# Online hosting

Online tournaments use a small Cloudflare Worker as a relay. The organizer's
phone remains authoritative: Cloudflare does not store decks, player profiles,
pairings, results, or tournament snapshots. The phone must stay connected for
players to use the event.

```text
Organizer Android app ── secure WebSocket ── Cloudflare relay
                                                   │
                                      secure WebSockets
                                                   │
                                           player browsers
```

LAN mode is still available and does not use Cloudflare or require internet.

## One-time Cloudflare setup

A free Cloudflare account, Node.js 22+, and a `workers.dev` subdomain are
sufficient. Do not
paste a Cloudflare password or API token into source files, chat, or GitHub.
Authenticate Wrangler through its browser flow instead:

```shell
cd cloudflare
npm ci
npx wrangler login
npm test
npm run deploy
```

The final command prints a URL similar to:

```text
https://mtg-tournament-relay.<your-subdomain>.workers.dev
```

For a local protocol smoke test, start `npm run dev` and then run this from the
repository root:

```shell
dart run tool/relay_smoke.dart http://127.0.0.1:8787
```

Cloudflare's official references:

- [Wrangler login and deployment](https://developers.cloudflare.com/workers/wrangler/commands/#login)
- [Durable Object WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- [`workers.dev` routes](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/)

## Configure and build the app

The relay address is a public build-time value, not a secret. Pass it when
running or building Flutter:

```shell
flutter run --dart-define=MTG_RELAY_URL=https://mtg-tournament-relay.<your-subdomain>.workers.dev
flutter build apk --release --dart-define=MTG_RELAY_URL=https://mtg-tournament-relay.<your-subdomain>.workers.dev
```

Without `MTG_RELAY_URL`, LAN tournaments continue to work and the app explains
that Online hosting is not configured when it is selected.

## Creating a tournament

The creation screen requires the organizer to choose one mode:

- **Online** — the QR code opens a public HTTPS page and players may join from
  any network. The organizer's phone and every player need internet access.
- **LAN** — the QR code points directly to the organizer's phone. Players must
  use the same Wi-Fi network, but the tournament can run without internet.

If an online connection drops, the app keeps the tournament state locally and
reconnects automatically. Player commands are rejected while the host is
offline rather than queued, avoiding duplicate match results. The notification
action pauses hosting deliberately; it is separate from a temporary outage.

Relay rooms expire after 24 hours to avoid accumulating abandoned free-tier
resources. The app automatically creates a fresh room after expiry without
losing tournament state; the organizer must share the replacement link shown in
the lobby. If that recovery cannot connect immediately, **Retry** tries again.

## Data and security

Each online event receives a random room identifier and a separate host secret.
Only the secret hash and room expiry metadata are stored in the Durable Object.
The raw host secret is kept in the Android app's local documents directory, is
excluded from both Google Drive and Android system backups, and is removed when
the event ends.

The public relay accepts only the five player operations used to join, register
a deck, enter, submit a result, and confirm/report an infraction. Organizer
commands are never exposed through it. Online traffic is encrypted by HTTPS and
WSS. LAN traffic remains cleartext and should only be used on a trusted network.

## Free-tier expectations

The relay is designed for Cloudflare's Workers Free plan and hibernates while
WebSockets are idle. Each room accepts at most 128 simultaneous player-browser
connections; the app's normal target is tournaments of up to 64 players. A
payment method is not required for the intended hobby deployment. Free-plan
quotas still apply; if they are exceeded, new requests can fail until the quota
resets. A `workers.dev` deployment is appropriate for personal/hobby use, not a
business-critical service.
