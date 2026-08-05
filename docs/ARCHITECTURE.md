# Architecture

This document describes the implementation in the repository today. For the
broader product specification and future requirements, see
[REQUIREMENTS.md](REQUIREMENTS.md).

## System overview

MTG Tournament has two user interfaces and one authoritative state:

1. The organizer uses a Flutter Android app.
2. Players use a small vanilla JavaScript client in their phone browsers.
3. A Dart controller inside the organizer app owns all tournament state and
   exposes it through an embedded HTTP/WebSocket server.

```text
┌──────────────────────── Android host process ────────────────────────┐
│ Flutter UI → HostController → ServerController → TournamentEngine   │
│                    │              │                                  │
│                    │              └─ JSON persistence                │
│                    ├─ shelf REST + WebSocket server (0.0.0.0:8080)   │
│                    ├─ foreground-service lifecycle                   │
│                    ├─ cached Scryfall images                         │
│                    └─ optional Google Drive backup                   │
└──────────────────────────────┬────────────────────────────────────────┘
                               │ trusted Wi-Fi/LAN
                    ┌──────────▼──────────┐
                    │ Player web clients │
                    │ assets/web/*       │
                    └─────────────────────┘
```

The foreground service keeps the Android process eligible to continue hosting
while the app is backgrounded. The server currently runs in the app's Dart
isolate; it is not a separate server isolate.

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
| `lib/host/host_controller.dart` | Host lifecycle, local identity, service control, card prep, and cloud sync |
| `lib/services/` | Scryfall integration, image cache, and Google Drive backup |
| `lib/ui/` | Organizer-facing Flutter screens |
| `assets/web/` | Player-facing HTML, CSS, and JavaScript |

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
- Ending an event archives a started tournament, stops the LAN listener, and
  preserves durable profiles and decks.

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

## Offline model

Tournament operation depends only on the host device and local network. The two
optional internet paths are deliberately outside the match flow:

- Scryfall resolves card names and downloads images during deck preparation.
- Google Drive signs in and backs up/restores the complete JSON document.

Typed deck text and tournament operation continue to work if either service is
unavailable. Cached card images are served by the host over the LAN.

## Trust and security model

The current transport is cleartext HTTP/WebSocket because the host advertises a
private IPv4 address and browsers must connect without certificate setup. The
design therefore assumes a trusted, isolated local network.

- Session and host authority use bearer UUID tokens.
- The server never accepts a client-selected deck identifier unless that deck
  already belongs to the authenticated player.
- Decks entered in a running event are immutable.
- Host-only reports are not included in ordinary player snapshots.
- Card-image identifiers are checked before they are mapped to filesystem paths.

Do not forward the server port, expose it to the internet, or publish captured
tokens. Stronger protection for hostile shared networks would require a pairing
proof and authenticated transport, not only UI changes.

## Validation

The repository tests pure tournament behavior, Swiss pairings, persistence and
backup round trips, statistics, controller snapshots, and the HTTP surface in
memory. The required checks are:

```shell
dart format --output=none --set-exit-if-changed lib test bin
flutter analyze
flutter test
```

GitHub Actions runs the same checks for pushes and pull requests.

## Known limitations

- LAN discovery selects the first non-loopback IPv4 address; devices with VPNs
  or multiple active adapters may need a more explicit interface selector.
- HTTP/WebSocket traffic is not encrypted or mutually authenticated.
- The player client and Dart snapshot schema are maintained manually rather
  than generated from a shared protocol definition.
- Persistence is a single JSON document rather than a transactional database.
- Release signing and Google OAuth configuration are deployment-owner concerns
  and are intentionally excluded from version control.
