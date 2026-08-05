# Architecture

This document describes the implementation in the repository today. For the
broader product specification and future requirements, see
[REQUIREMENTS.md](REQUIREMENTS.md).

## System overview

MTG Tournament has two user interfaces and one authoritative state:

1. The organizer uses a Flutter Android app.
2. Players use a small vanilla JavaScript client in their phone browsers.
3. A Dart controller inside the organizer app owns all tournament state and
   exposes it either through the embedded LAN server or an outbound connection
   to the public relay.

```text
┌──────────────────────── Android host process ────────────────────────┐
│ Flutter UI → HostController → ServerController → TournamentEngine   │
│                    │              │                                  │
│                    │              └─ JSON persistence                │
│                    ├─ LAN: shelf HTTP/WebSocket server (:8080)       │
│                    ├─ Online: outbound WebSocket relay client        │
│                    ├─ foreground-service lifecycle                   │
│                    ├─ cached Scryfall images                         │
│                    └─ optional Google Drive backup                   │
└──────────────────────────────┬────────────────────────────────────────┘
                 ┌─────────────┴──────────────┐
          trusted Wi-Fi/LAN             internet/WSS
                 │                           │
         ┌───────▼────────┐       ┌──────────▼──────────┐
         │ player browser │       │ Cloudflare relay DO │
         └────────────────┘       └──────────┬──────────┘
                                            │ WSS
                                     ┌──────▼─────────┐
                                     │ player browser │
                                     └────────────────┘
```

The `remoteMessaging` foreground service keeps the Android process eligible to
continue relaying tournament messages while the app is backgrounded. This is
the Android service type intended for local servers that relay messages across
devices; unlike `dataSync`, it is not subject to Android 15's six-hour timeout.
The server currently runs in the app's Dart isolate; it is not a separate
server isolate.

## Module boundaries

| Module | Responsibility |
| --- | --- |
| `lib/shared/models.dart` | Serializable tournament, player, deck, round, and match types |
| `lib/shared/swiss.dart` | Pure Swiss pairing and tiebreak calculations |
| `lib/shared/tournament_engine.dart` | Tournament lifecycle and match state machine |
| `lib/shared/stats.dart` | Cross-event player and deck statistics |
| `lib/server/controller.dart` | Durable registries, command orchestration, snapshots, and archive views |
| `lib/server/server.dart` | REST routes, WebSocket connections, static assets, and LAN binding |
| `lib/server/persistence.dart` | File and in-memory JSON persistence adapters |
| `lib/host/host_controller.dart` | Mode-aware host lifecycle, local identity, service control, card prep, and cloud sync |
| `lib/host/online_relay.dart` | Online room provisioning, reconnect, and virtual browser connections |
| `lib/services/` | Scryfall integration, image cache, and Google Drive backup |
| `lib/ui/` | Organizer-facing Flutter screens |
| `assets/web/` | Player-facing HTML, CSS, and JavaScript |
| `cloudflare/` | Stateless Worker entry point and per-room Durable Object relay |

`lib/shared/` and `lib/server/` remain usable from the standalone Dart server
and contain no Flutter UI dependencies.

## State and persistence

`ServerController` owns the live registries for players, decks, card metadata,
session tokens, the active `TournamentEngine`, and archived engines. A mutation
follows this order:

1. Validate authority and state-machine preconditions.
2. Mutate the in-memory model.
3. Serialize the complete durable state to JSON.
4. Notify the Flutter UI and connected browsers with fresh snapshots.

The Android app writes `tournament.json` in its application documents
directory. The whole JSON document is also the unit of optional Drive backup.
Imports are decoded into temporary collections and adopted only after the full
document validates, so a malformed backup cannot partially erase live state.

## Tournament lifecycle

The state machine uses `lobby`, `running`, and `finished` phases.

- The host creates an event and receives a short join code.
- Players establish a token-backed session, save a deck, and enter the lobby.
- Starting the tournament locks entered decks and creates round one.
- Players submit scores independently in canonical match orientation.
- Matching scores reveal decklists and begin the post-match infraction check.
- A mismatch or reported infraction moves the match to host review.
- Every match must be confirmed before the host can advance the round.
- Ending an event archives a started tournament, closes its selected transport,
  and preserves durable profiles and decks.

The pairing engine is deterministic when supplied a seeded `Random`, which
keeps it straightforward to regression-test.

## HTTP and realtime boundary

The browser client sends mutations over JSON REST endpoints and receives state
through snapshots and WebSocket pushes. Important route groups are:

| Routes | Purpose |
| --- | --- |
| `/api/join`, `/api/deck`, `/api/enter` | Session, deck, and event entry |
| `/api/result`, `/api/infraction` | Player match commands |
| `/api/host/*` | Host-authorized lifecycle and adjudication commands |
| `/api/snapshot`, `/ws` | Initial and realtime read models |
| `/cards/img/<id>` | Cached card images |

Snapshots are tailored to the authenticated viewer. Host-only pairing reports,
infraction reporter names, and adjudication details are excluded from player or
anonymous snapshots.

In Online mode the browser sends those same five player mutations through its
WebSocket. A Durable Object assigns the browser an opaque connection ID and
forwards frames to the host phone. The phone maps each browser to the existing
`Connection` abstraction and dispatches allowed mutations against the same
in-memory Shelf handler. `/api/host/*` is not relayable. The relay keeps only a
host-secret hash and expiry metadata; tournament payloads remain transient.

## Connectivity model

LAN tournament operation depends only on the host device and local network.
Online tournaments additionally require internet access for the host and
players; a temporary outage is shown as reconnecting and does not discard or
manually pause the local tournament.

Two other internet paths remain outside the match flow:

- Scryfall resolves card names and downloads images during deck preparation.
- Google Drive signs in and backs up/restores the complete JSON document.

Typed deck text and tournament operation continue to work if either service is
unavailable. Cached card images are served by the host over the LAN.

## Trust and security model

LAN transport is cleartext HTTP/WebSocket because the host advertises a private
IPv4 address and browsers connect without certificate setup. It therefore
assumes a trusted, isolated network. Online transport is HTTPS/WSS terminated by
Cloudflare and uses a high-entropy room identifier plus a separate host secret.

- Unknown client-selected session tokens are replaced with server-generated
  UUIDs; returning known tokens retain their existing identity.
- The online relay accepts only player command paths and never host/admin paths.
- Online host credentials are kept in a separate local file, outside the Drive
  backup blob and Android system backups, and cleared when the event ends.
- The server never accepts a client-selected deck identifier unless that deck
  already belongs to the authenticated player.
- Decks entered in a running event are immutable.
- Host-only reports are not included in ordinary player snapshots.
- Card-image identifiers are checked before they are mapped to filesystem paths.

Do not forward the LAN server port or publish captured tokens. Use Online mode
when players are not on a trusted shared network.

## Validation

The repository tests pure tournament behavior, Swiss pairings, persistence and
backup round trips, statistics, controller snapshots, and the HTTP surface in
memory. The required checks are:

```shell
dart format --output=none --set-exit-if-changed lib test bin tool
flutter analyze
flutter test
cd cloudflare
npm ci
npm run check
```

GitHub Actions runs the Flutter and relay checks for pushes and pull requests.

## Known limitations

- LAN discovery selects the first non-loopback IPv4 address; devices with VPNs
  or multiple active adapters may need a more explicit interface selector.
- LAN HTTP/WebSocket traffic is not encrypted or mutually authenticated.
- Online mode still depends on the organizer phone remaining connected; the
  Cloudflare component is a relay, not an authoritative tournament backend.
- Online browser sessions are scoped to one random room. A participant retains
  identity across reconnects to that room, but a new online event does not
  automatically recover that browser's decks from an earlier room.
- The player client and Dart snapshot schema are maintained manually rather
  than generated from a shared protocol definition.
- Persistence is a single JSON document rather than a transactional database.
- Release signing and Google OAuth configuration are deployment-owner concerns
  and are intentionally excluded from version control.
