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
| `lib/shared/swiss.dart` | Pure pairing, tiebreak, and round-count calculations |
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

## History, revisions, and statistics

Two rules keep historical data honest.

**A tournament entry references an immutable `DeckRevision`, not a deck.** A
`Deck` stays editable forever, so pointing history at a deck id would mean that
editing a deck silently rewrites results from months ago. Entering a tournament
freezes the list; revision ids are content-addressed, so re-entering an
unchanged deck reuses one and two devices holding the same list agree on the
same id. Saves written before revisions existed are back-filled on load from
the deck's current list and flagged `migrated`, and every screen that shows
such a list says it was reconstructed.

**Statistics are folds over a fact table, never computed in a widget.**
`ServerController.matchFacts()` denormalizes every settled match into a
`MatchFact` carrying the deck revision, archetype, format, series, round, and
whether the result was disputed or host-adjudicated. `StatsService` turns
(facts, filter, subject) into plain report objects: tournament, player, deck,
revision, head-to-head, matchup matrix, monthly trends, and Glicko-2 rating
history. Every rate travels with its sample size and a Wilson interval, so the
UI can never present a 3-1 record as a 75% deck.

The store remains the single JSON document rather than a relational database:
the fact table is rebuilt on demand from a few thousand matches at most, which
keeps the whole statistics layer pure Dart and testable without a device.

`lib/server/interchange.dart` handles versioned bundles. Imports are staged
and validated in full before any live state is touched, and are additive and
idempotent: existing records win, new ones are appended, nothing is deleted.
Players are matched by stable id only — a shared nickname is surfaced as a
suggestion the organizer must confirm, never an automatic merge.

## Post-match questionnaire

An optional questionnaire opens when a non-bye match is confirmed and asks only
for facts the app cannot derive: per-game results, mulligans, who was on the
play, whether anyone sideboarded. It expires on a timer, closes when the round
advances, and has no path to change a confirmed result — submitting, skipping,
and ignoring it are identical as far as the tournament is concerned. Raw
answers are private to the answering player and to a full local backup; when
both players answer, incompatible accounts are recorded as conflicts for the
organizer rather than reconciled to one side.

## Tournament lifecycle

The state machine uses `lobby`, `running`, and `finished` phases.

- The host creates an event, choosing Swiss or single elimination, and receives
  a short join code.
- Players establish a token-backed session, save a deck, and enter the lobby.
- Starting the tournament locks entered decks and creates round one.
- Players submit scores independently in canonical match orientation.
- Matching scores reveal both decklists. The list is shown, not hidden behind a
  tap: checking it is the point of the step.
- Each player confirms the opponent's decklist or flags it.
- A score mismatch or a flagged decklist moves the match to host review. Every
  such match waits its turn; resolving one never clears another.
- The organizer resolves a review by amending the result, letting it stand, or
  disqualifying one or both players.
- A confirmed match opens its optional questionnaire.
- Every match must be confirmed before the host can advance the round. The
  advance stays a deliberate press: doing it automatically would close the
  questionnaire windows the instant the last match landed.
- Ending an event archives a started tournament, closes its selected transport,
  and preserves durable profiles and decks.

The pairing engine is deterministic when supplied a seeded `Random`, which
keeps it straightforward to regression-test.

Standings sort by match points, then opponents' match-win %, then game-win %,
then opponents' game-win % (MTR Appendix C), and every screen shows all four so
a player can see why they are where they are. A disqualification is recorded on
the entry rather than inferred from a drop, and a double disqualification is
stored as a 0-0 `GameScore` — the one score `isDraw` deliberately excludes, so
it awards no match point to either player.

### Structure, rounds, and the clock

Swiss pairs everyone every round and plays `recommendedRounds(players)` of them
(MTR Appendix E: the rounds needed to leave one undefeated player, so the count
doubles with the field). The organizer may override that number before or
during the event, but never below the rounds already paired. Single elimination
pairs only the previous round's winners; its length is `bracketRounds(players)`
and is not adjustable, because it is arithmetic rather than a preference. A
drawn knockout match stops the bracket with an error instead of choosing a
winner — no tiebreaker can settle it, so it is the organizer's call.

Generated pairings are editable until they are played: `swapPairing` exchanges
two seats in the current round, including the bye, and refuses any match that
already carries a submitted or accepted result. Match ids survive the swap, so
anything already referring to a match stays valid.

The round timer is a wall clock and nothing more. `Round.endsAt` is an absolute
deadline pushed to every client (so a client that misses an update still counts
down to the right moment), set when a round is paired and re-settable by the
host. No command reads it: a round that runs out of time still needs the
organizer to resolve and advance it.

## HTTP and realtime boundary

The browser client sends mutations over JSON REST endpoints and receives state
through snapshots and WebSocket pushes. Important route groups are:

| Routes | Purpose |
| --- | --- |
| `/api/join`, `/api/deck`, `/api/enter` | Session, deck, and event entry |
| `/api/result`, `/api/infraction` | Player match commands |
| `/api/survey` | Optional post-match questionnaire (never affects a result) |
| `/api/host/*` | Host-authorized lifecycle and adjudication commands |
| `/api/snapshot`, `/ws` | Initial and realtime read models |
| `/cards/img/<id>` | Cached card images |

Snapshots are tailored to the authenticated viewer. Host-only pairing reports,
infraction reporter names, adjudication details, and other players'
questionnaire answers are excluded from player or anonymous snapshots — a
viewer only ever sees their own answers plus whether the opponent responded.

In Online mode the browser sends those same six player mutations through its
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

- LAN HTTP/WebSocket traffic is not encrypted or mutually authenticated.
- Online mode still depends on the organizer phone remaining connected; the
  Cloudflare component is a relay, not an authoritative tournament backend.
- Online browser sessions are scoped to one random room, because a session
  token only means anything to the host that issued it. A participant keeps
  their identity across reconnects to that room; entering a new room is a new
  identity, so the host has none of their decks. The client softens this by
  keeping the last list typed and the nickname in device-local storage and
  offering them back — but the host still records a separate player.
- The player client and Dart snapshot schema are maintained manually rather
  than generated from a shared protocol definition.
- `/api/host/*` exposes only the original create/start/advance/resolve/drop
  commands. Round counts, pairing edits, and the round timer are driven from
  the organizer app against the controller directly, as event format and series
  already were.
- Persistence is a single JSON document rather than a transactional database.
  The statistics layer is written against a fact table and typed report
  services, so swapping the store for SQLite would not change any formula.
- A player who has the app installed still joins events through the browser
  client; the app has no player mode that reuses their local profile and decks.
- Release signing and Google OAuth configuration are deployment-owner concerns
  and are intentionally excluded from version control.
