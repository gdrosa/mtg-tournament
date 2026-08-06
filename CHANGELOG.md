# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- Single-elimination events alongside Swiss: losers are knocked out and the
  bracket length follows from the entrant count. A drawn knockout match stops
  the bracket for the organizer to resolve rather than picking a winner.
- Manual round count for Swiss, before or during an event. It can never fall
  below the rounds already paired.
- Manual pairing edits: tap two players to swap their seats before the round is
  played (the bye included). A match that already has a reported result cannot
  be re-paired.
- Optional round timer, configurable at creation or mid-event, shown to the
  organizer and to every player. It is a wall clock: it never ends a round,
  changes a result, or advances anything.

- Statistics tab: one filter (date, format, series, tournament, player,
  opponent, deck, archetype, byes) applied across players, decks, archetypes
  and events, with player and deck profile screens behind it.
- Immutable deck revisions. Entering a tournament freezes the exact list, so
  editing a deck can no longer rewrite what was played; deck profiles compare
  revisions and show the cards added and removed between them.
- Per-tournament report: rank progression, archetype distribution, matchup
  matrix, and counts of byes, draws, drops, disputes and adjudicated results.
- Glicko-2 ratings with a rating deviation, so a two-match record is never
  presented as a settled one. Every rate is shown with its sample size and a
  95% interval.
- Optional post-match questionnaire (game results, mulligans, play/draw,
  sideboarding). It expires, never blocks a round, never changes a confirmed
  result, keeps each player's answers private from their opponent, and records
  conflicting accounts instead of picking one.
- Versioned import/export: full backup, one tournament, a player history, a
  deck library, CSV, and anonymized aggregates. Imports are previewed, atomic,
  idempotent and cumulative — they add to your data and never replace it.
- Optional format and series/league on an event, and an optional archetype on
  a deck, purely as grouping labels for statistics.

### Changed

- Decklist reveal and tournament history show the list as registered for that
  event, and mark a list as reconstructed when it predates deck revisions.

### Fixed

- Default Swiss round counts. Every field of 8 or fewer players was given 3
  rounds and every field of 9 to 16 got 5; 4 players now correctly play 2
  rounds and 16 play 4, per MTR Appendix E.

## [0.0.3] - 2026-08-05

### Added

- Update check at launch and from Profile: offers the newest stable GitHub
  release and asks before installing it. Pre-releases are never offered.
- One decklist box when registering a deck: a "Sideboard" line splits the
  paste, otherwise a 75-card list is read as 60 + 15.

### Changed

- Resolve unknown card names in one batched Scryfall request instead of one
  per card (a 31-name decklist: 64s to 1.8s).

### Security

- Restrict relay room creation to builds carrying a provisioning key, with
  `cloudflare/keys.mjs` to issue and revoke keys.
- Ask the organizer for a provisioning key when the relay rejects the build's
  own, so revoking a key does not strand installed apps.

## [0.0.2] - 2026-08-05

### Added

- Per-tournament Online or LAN hosting choice.
- Free Cloudflare Worker/Durable Object relay for internet players.
- Automatic host reconnection, room-scoped browser sessions, and online status UI.
- Relay protocol, security, widget, persistence, and end-to-end smoke tests.
- Profile export: share the local save (decks, history, stats) as gzipped JSON.
- Deck profile pictures set from the clipboard or the device gallery.

### Security

- Restrict relayed traffic to player commands and bind commands to each virtual
  browser connection's session token.
- Replace unknown client-selected bearer tokens with server-generated UUIDs.
- Keep online host credentials in local transport storage outside Drive backups.
- Strip session tokens and the active join code from the shareable export.

## [0.0.1] - 2026-08-05

### Added

- Android organizer app with embedded LAN HTTP/WebSocket server.
- Browser-based player joining through QR code, URL, or event code.
- Swiss pairings, standings, dual result confirmation, infraction review, and round gating.
- Local profiles, named decks, tournament history, and aggregate statistics.
- Scryfall card lookup with an offline image cache.
- Optional private Google Drive backup.
- Automated formatting, analysis, and test checks for GitHub.

### Fixed

- Keep infraction reviews locked until the organizer adjudicates them.
- Import backups atomically so malformed data cannot partially clear live state.
- Lock entered decklists once a tournament starts.
- Restrict adjudication reports and infraction reporter names to host snapshots.
- Close the LAN listener when an event ends.
- Ignore stale or failed card-search responses in the deck editor.

### Repository

- Reorganized product documentation and curated screenshots under `docs/`.
- Excluded local tokens, device captures, interview artifacts, signing material,
  caches, and build output from version control.
