# Changelog

All notable changes to this project are documented here.

## [Unreleased]

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
