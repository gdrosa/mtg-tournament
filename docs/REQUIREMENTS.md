# MTG Tournament Manager — Requirements

> Product requirements for a **Magic: The Gathering** tournament manager with
> selectable local-network (LAN) and online hosting.
> Derived from owner interviews and written architecture decisions.
> See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the current implementation and
> [`../README.md`](../README.md) for setup and development commands.

This is the product specification, not an implementation checklist. Some
"Should" and "Could" requirements remain planned; the architecture document
describes what the repository implements today.

## 1. Product summary

One person — the **organizer / host** — runs an Android app on their phone. That app hosts the entire tournament. Other players join from their own phones' **browsers** by scanning a QR code or typing a short URL — **no app to install**. The host is simultaneously a **player and the admin** (full organizer controls). During creation, the host chooses either LAN (same Wi-Fi, offline-capable) or Online (internet access through the project relay).

### Online-hosting extension (2026-08-05)

- The creation flow must require an explicit **Online** or **LAN** choice.
- LAN retains the embedded phone server and offline behavior specified below.
- Online uses an outbound phone connection to a free relay; the phone remains
  authoritative and must stay connected.
- The relay must not persist tournament payloads or expose organizer commands.
- A temporary online outage must reconnect without becoming a manual pause or
  discarding tournament state.
- Online browser sessions must be scoped by a high-entropy room ID. The existing
  event code remains a human confirmation that the player opened the intended
  tournament; it is not an authentication secret.

The tournament runs **Swiss rounds** of **best-of-three** matches. Both players in a match enter the result independently; the app accepts it only when the two submissions agree. After a match each player sees the opponent's decklist and confirms "no infractions" (thumbs up / thumbs down). A round advances only when every match is confirmed; any disagreement or reported infraction is escalated to the host for review instead of auto-advancing. Results are stored per **named deck** (e.g. *"Domain Zoo"*) so the app can report how each deck performs across tournaments and against specific opponents.

## 2. Source material

| Source | Content |
|---|---|
| Owner interview 1 | Product vision: registration & nickname, written deck + sideboard lists, named decks, host-created event joined by unique id, Swiss bracket generation, round/match management, best-of-3, dual independent result entry & reconciliation, post-match decklist reveal, thumbs up/down infraction check, round gating, escalation/suspension to the host on disagreement, per-named-deck results database. |
| Owner interview 2 | Scope note: a more elaborate version would add **card images**, but that raises complexity substantially. |
| Four written architecture decisions | (1) An installable Android **APK**. (2) The app runs on the host phone and opens the tournament on the **LAN**. (3) Players use the LAN link from a **browser — no install**. (4) Players control everything from the web UI; the host app user is **both a player and the admin**. |

## 3. Actors

- **Player** — registers, builds one or more named decks, joins a tournament, plays matches, enters results, confirms infractions, views pairings/standings.
- **Host / Organizer** — a Player who also created the event and holds **full admin authority**: pairings overrides, dispute resolution, dropping players, advancing/closing rounds, result overrides.
- **System** — the host Android app plus its embedded LAN server, which holds all **authoritative** tournament state.

## 4. Priority key (MoSCoW)

**Must** = required for a working v1 · **Should** = important, plan early · **Could** = nice-to-have / later.

Totals: **52 functional** + **40 non-functional** = 92 requirements (58 Must · 28 Should · 6 Could). *(FR-51/FR-52 added 2026-06-14 from owner feedback.)*

## 5. Functional requirements

### 5.1 Accounts, roles & access

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-01 | Must | **Player self-registration** — A person can register themselves as a player in the system without requiring an organizer to create their account. | voice 1 |
| FR-02 | Must | **Receive/choose a nickname** — Upon registration each player is assigned or chooses a nickname that uniquely identifies them within the app and is shown in pairings, standings and results. | voice 1 |
| FR-03 | Should | **Nickname uniqueness validation** — The system rejects or disambiguates a nickname that collides with an existing one so every player is individually identifiable. | implied |
| FR-04 | Must | **Host is player and admin simultaneously** — The person who runs the app (host) is registered as a player AND holds full organizer/admin privileges over the tournament at the same time. | idea 4 |
| FR-05 | Must | **Players join via browser without install** — Players access the tournament interface from their own phone's browser over the same Wi-Fi/LAN using a link served by the host phone, without installing any application. | idea 3 |
| FR-06 | Must | **Host runs native Android app serving the LAN interface** — The host installs and runs an Android APK that runs natively on the phone and serves the tournament web interface to player clients over the LAN. | idea 1 |
| FR-48 | Should | **Browser session and reconnection** — Player browser clients maintain a session and can reconnect (e.g. after losing Wi-Fi, refreshing, or backgrounding the browser) without losing their place in the tournament. | implied |
| FR-49 | Must | **Organizer full control panel** — The host has an organizer control surface exposing all tournament options: editing pairings, resolving flagged matches, dropping players, advancing/closing rounds, and overriding results. | idea 4 |

### 5.2 Deck registration

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-07 | Must | **Register maindeck list as text** — A player can register their deck by entering a written maindeck list of at least 60 cards as free text. | voice 1 |
| FR-08 | Must | **Register sideboard list as text** — A player can register a separate sideboard list of 15 cards as free text, distinct from the maindeck list. | voice 1 |
| FR-09 | Must | **Name a deck (archetype label)** — A player can assign a name (e.g. "Domain Zoo") to a registered deck so its results can be tracked per named archetype. | voice 1 |
| FR-10 | Should | **Maindeck minimum size validation** — The system validates that the maindeck list contains at least 60 cards before the deck can be used in a tournament. | implied |
| FR-11 | Should | **Sideboard size validation** — The system validates that the sideboard list contains at most 15 cards before the deck can be used in a tournament. | implied |
| FR-12 | Should | **Maintain multiple decks per player** — A player can have more than one registered/named deck stored and select which one to bring to a given tournament. | implied |
| FR-13 | Should | **Edit or update a registered deck** — A player can edit the maindeck, sideboard, or name of a registered deck before it is locked into a running tournament. | implied |
| FR-50 | Could | **Show card images for decklists (elaborate version)** — An optional, higher-complexity version displays card images for decklists in addition to the text lists. | voice 2 |

### 5.3 Tournament lifecycle

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-14 | Must | **Host creates a tournament event** — A single person acting as host can create a new tournament event in the app. | voice 1 |
| FR-15 | Must | **Generate unique tournament id** — On creation the system generates a unique tournament id that players use to join the specific event. | voice 1 |
| FR-16 | Must | **Players join tournament via unique id** — A registered player joins a tournament by entering its unique id and selecting the registered deck they will play. | voice 1 |
| FR-17 | Must | **Submit registered deck on join** — When joining, a player attaches one of their previously registered/written decks to their tournament entry. | voice 1 |
| FR-18 | Should | **Tournament lifecycle states** — A tournament progresses through defined states: created, lobby (players joining), running (rounds in progress), and finished. | implied |
| FR-19 | Should | **Lobby view of joined players** — Before the tournament starts, the host and players can see the list of players who have joined and their selected (named) decks. | implied |
| FR-20 | Must | **Host starts the tournament** — The host transitions the tournament from lobby to running, locking the player roster and generating round 1. | voice 1 |
| FR-21 | Should | **Host finishes/closes the tournament** — The host can end the tournament, transitioning it to a finished state with final standings recorded. | implied |
| FR-51 | Must | **Stop the background service from the notification** — While hosting, the persistent foreground-service notification exposes a *Stop hosting* button that tears down the LAN server and foreground service **without discarding the event**. The tournament stays durably saved and the host can *Resume hosting* (restart the server/service) or *End event* (archive it). Distinct from FR-21's close-and-archive. | owner request 2026-06-14 |

### 5.4 Pairings & rounds (Swiss)

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-22 | Must | **Generate Swiss-style bracket pairings** — During the tournament the app generates pairings using a Swiss bracket system for each round. | voice 1 |
| FR-23 | Should | **Swiss pairing by record** — Swiss pairings match players against opponents with similar win/loss records and avoid repeat pairings where possible. | implied |
| FR-24 | Should | **Assign byes for odd player counts** — When the number of active players in a round is odd, the system assigns a bye (counted as a win) to an eligible player who has not yet received one. | implied |
| FR-25 | Should | **Organizer manual pairing edits/overrides** — The host/organizer can manually adjust or override generated pairings before a round begins. | implied |
| FR-26 | Must | **Live view of current pairings** — Players and the host can view the current round's pairings (their match-ups and table assignments) live during the tournament. | implied |
| FR-27 | Must | **Manage rounds and match-ups** — The app manages the sequence of rounds and the individual match-ups within each round. | voice 1 |
| FR-37 | Must | **Round gating until all matches confirmed** — The system waits until every match in the current round is fully confirmed before allowing advancement to the next round. | voice 1 |
| FR-38 | Must | **Generate next round when round is clean** — Once all matches in the round are confirmed with no discrepancies or flagged infractions, the system generates the next round's Swiss pairings. | voice 1 |
| FR-41 | Should | **Organizer force-advance round after resolution** — After resolving all flagged matches, the host can advance the tournament to the next round. | implied |

### 5.5 Results, confirmation & disputes

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-28 | Must | **Best-of-3 match format** — Each match between two players is played as a best-of-three, and results are captured accordingly. | voice 1 |
| FR-29 | Must | **Both players independently enter the result** — After a match ends, each of the two players independently enters the final result through their own interface. | voice 1 |
| FR-30 | Must | **Reconcile and accept matching results** — The system compares the two independently submitted results and accepts the result only if both players submitted the same result. | voice 1 |
| FR-31 | Must | **Flag result discrepancy on mismatch** — If the two submitted results do not match, the system does not accept the result and flags the match as a discrepancy requiring resolution. | voice 1 |
| FR-32 | Must | **Reveal opponent decklists after acceptance** — Once a match result is accepted, the app shows each player the full decklist (maindeck and sideboard) of the opponent they just played. | voice 1 |
| FR-33 | Must | **Both players confirm no infractions (thumbs up/down)** — After viewing the opponent's decklist, both players confirm whether there were any infractions via a simple yes/no thumbs-up/thumbs-down control. | voice 1 |
| FR-34 | Must | **Match confirmed only when both approve** — A match is considered fully confirmed only when the result is accepted AND both players have given a thumbs-up (no infractions). | voice 1 |
| FR-35 | Must | **Flag infraction on thumbs-down** — If either player gives a thumbs-down (infraction reported), the match is flagged for organizer review instead of being confirmed. | voice 1 |
| FR-36 | Should | **Edit/resubmit result before acceptance** — A player can change their submitted result while the match is still pending reconciliation (before final acceptance). | implied |
| FR-39 | Must | **Send suspension/alert to host on discrepancy or infraction** — On a result mismatch or a flagged infraction, the system sends a suspension/alert to the host/organizer for manual review instead of auto-advancing the round. | voice 1 |
| FR-40 | Must | **Organizer manual review and resolution of flagged matches** — The host/organizer can review a flagged/suspended match and manually set or override the final result and clear the flag so the round can proceed. | voice 1 |
| FR-42 | Should | **Player drop/withdraw** — A player can drop or be withdrawn from a running tournament, after which they are excluded from future pairings. | implied |
| FR-46 | Must | **Standings display** — The system computes and displays tournament standings (ranking players by record/points) during and at the end of the tournament. | implied |
| FR-47 | Should | **Live standings updates** — Standings update live as matches are confirmed and rounds complete, visible to players and host. | implied |

### 5.6 Data & analytics

| ID | Pri | Requirement | Source |
|---|---|---|---|
| FR-43 | Must | **Persist players, decks, matches and results to a database** — The system stores players, their named decks, matches and results in a database for durable record-keeping. | voice 1 |
| FR-44 | Must | **Track results per named deck across tournaments** — The database records each named deck's results across all tournaments and against all opponents, keyed to the deck name. | voice 1 |
| FR-45 | Must | **Per-named-deck performance analytics** — The app reports how a named deck (e.g. "Domain Zoo") performs overall and against specific opponents/decks across all tournaments. | voice 1 |
| FR-52 | Must | **Manage previous tournaments** — The host can browse a history of finished tournaments (date, size, champion) and, for any one, **open** it to review final standings, the roster with named decks + decklists, and per-round results, or **delete** it from history. Deleting recomputes deck/player statistics; durable player & deck identities are retained. Surfaced in the Events tab + a tournament-detail screen, fed by the archive/`StatsEngine` read model. | owner request 2026-06-14 |

## 6. Non-functional requirements

### 6.1 Offline/LAN

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-13 | Must | LAN mode (host + client interface) must operate with zero internet connectivity on local Wi-Fi only. | 100% of core flows (register, deck entry, host event, join by ID, pairings, result entry/confirmation, opponent decklist view, advance round, standings) function in LAN mode with the phone in airplane mode + Wi-Fi/hotspot only; no outbound internet call is required on a LAN match path. |
| NFR-14 | Must | All client assets must be self-served by the host; no CDN, web font, analytics, or external dependency at runtime. | 0 external network requests observed in browser dev-tools network trace during a full tournament; all JS/CSS/fonts/icons bundled and served from the host phone. |
| NFR-15 | Should | Players must be able to discover and join the tournament on the LAN without typing complex configuration. | Join via single LAN URL (host IP:port) plus unique event ID, reachable by QR code and/or manual entry; join success <= 30 s from scan/entry; works when host runs a Wi-Fi hotspot as well as on shared Wi-Fi. |
| NFR-16 | Could | The host must tolerate LAN address changes (DHCP lease change / hotspot toggle) without invalidating an active tournament. | On host IP change, organizer can re-publish a new join URL/QR and all existing players' sessions remain valid and resumable; tournament state unaffected. |

### 6.2 Security

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-17 | Must | Define and enforce a LAN trust model: organizer holds full admin authority; players hold only player authority over their own data and matches. | Admin-only actions (create/cancel event, override result, advance/suspend round, drop player) require organizer authentication; 0 admin actions executable from a player session in penetration test. |
| NFR-18 | Must | A player must not be able to forge or submit their opponent's result confirmation; both-sides agreement is cryptographically/sessionally bound to distinct player identities. | Result is accepted only when two distinct authenticated player sessions independently submit matching results; a single session cannot satisfy both sides; forging another player's confirmation fails in 100% of attempts in adversarial test (no shared/guessable token). |
| NFR-19 | Must | Each player session must be authenticated with an unguessable, per-player credential bound to that session/device for the tournament duration. | Session tokens >= 128 bits entropy, unique per player, and not enumerable from event ID; Online transport protects them with WSS, while LAN mode retains the documented same-network interception risk. |
| NFR-20 | Must | On result mismatch or a reported infraction (thumbs-down), the system must auto-suspend the affected match/round and require organizer adjudication before advancing. | 100% of mismatched-result or flagged-infraction matches block automatic round generation and raise an organizer alert; round advances only after organizer resolution or all matches confirmed clean. |
| NFR-21 | Must | Organizer override of a result (the host is also a player) must require explicit admin authentication and be fully attributed, preventing self-favorable silent edits. | Every override records actor=organizer, before/after value, timestamp, reason; overrides are immutable in the audit log and visible in NFR-31 trail; 0 silent (unlogged) overrides possible. |
| NFR-22 | Must | Minimize personal data: store no PII beyond a self-chosen nickname and tournament/deck data; no email, real name, phone, or location required for players. | Player record contains only {nickname, deck name, decklist, results}; 0 mandatory PII fields beyond nickname; no device fingerprint persisted beyond the event. |
| NFR-23 | Should | Decklist confidentiality: an opponent's full decklist (main + sideboard) is revealed to a player only after that specific match's result is accepted, never before. | Decklist endpoint returns an opponent's list only for an accepted, mutually-confirmed completed match the requester played; 0 pre-match or non-opponent decklist disclosures in access-control test. |
| NFR-40 | Could | LAN transport should protect session tokens against passive sniffing on shared Wi-Fi where feasible given no-internet/no-CA constraints. | Prefer self-signed TLS over LAN with organizer-displayed fingerprint; if plain HTTP is used due to certificate-trust friction, document the same-LAN threat and bind tokens to short-lived sessions to limit exposure. |

### 6.3 Reliability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-08 | Must | The host server process must survive the phone screen turning off and the app being backgrounded, continuing to serve clients and accept results. | Server stays reachable and responsive with screen off and app backgrounded for >= 4 hours continuous (typical tournament length) using an Android foreground service + wake lock; 0 dropped tournaments attributable to backgrounding in test. |
| NFR-09 | Must | No committed tournament data may be lost if the host app crashes or the phone is force-killed/restarted mid-tournament. | All accepted results, confirmations, pairings, and registrations are durably persisted (fsync/transaction-committed) before acknowledgement; recovery test (kill -9 / battery pull) loses 0 confirmed records across 50 trials. |
| NFR-10 | Must | An in-progress tournament must be resumable to its exact prior state after a host app or phone restart. | After cold restart, organizer can resume the active tournament restoring round number, pairings, submitted/confirmed results, and pending-confirmation state with 100% fidelity in <= 10 s; clients reconnect automatically (re-scan/refresh) and regain their correct view. |
| NFR-39 | Must | Concurrent result submissions for many simultaneously-finishing matches must be handled without race conditions or lost/double-counted results. | Under 32 simultaneous match-result submissions, 0 lost updates and 0 double-advances; result acceptance is idempotent and serialized per match. |

### 6.4 Availability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-11 | Should | The host service must auto-recover (restart and reload last state) without manual reinstall if the process is killed by the Android OS for memory. | Foreground service auto-restarts and reloads tournament state within <= 15 s of OS kill; battery-optimization exemption guidance shown to organizer at setup. |
| NFR-12 | Must | Transient client disconnects (player phone sleeps, Wi-Fi drops) must not lose match progress and must reconnect seamlessly. | Client reconnect and full state resync within <= 5 s of network restoration; any result/confirmation submitted before disconnect is preserved server-side; no duplicate submissions on reconnect (idempotent). |

### 6.5 Data/Persistence

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-33 | Must | All tournament, player, deck, and result data persisted in a durable on-device local database with ACID transactional writes. | Use embedded ACID store (e.g. SQLite/Room); every accepted result committed in a single transaction; DB integrity check passes after simulated crash in 100% of trials. |
| NFR-34 | Should | Organizer can export and back up tournament and deck-history data, and import/restore it, without internet. | One-tap export of a full tournament and the deck-stats DB to a portable file (JSON and/or CSV, plus raw DB) saved to device storage; restore reproduces state with 100% fidelity; export of a 64-player completed event <= 5 s. |
| NFR-35 | Should | Persisted data schema must support forward migration across app versions without data loss. | Versioned schema with automated migrations; upgrading across one major version preserves 100% of historical tournaments and deck records; migration is transactional with rollback on failure. |
| NFR-36 | Could | Deck identity for cross-tournament stats must be stable and unambiguous so per-deck win-rate history aggregates correctly over time. | Each deck has a stable internal ID independent of its display name; renaming a deck preserves linked history; per-deck and head-to-head aggregates remain consistent across >= 50 tournaments. |

### 6.6 Performance

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-01 | Must | Swiss pairing generation for a round must complete fast enough to feel instant to the organizer on mid-range Android hardware. | <= 500 ms to generate pairings for up to 32 players, <= 1.5 s for 64 players, measured on a phone with a 4-core ARM CPU and 4 GB RAM (e.g. Snapdragon 6-series class), single-threaded. |
| NFR-02 | Must | Player-facing web UI interactions (tap to submit result, confirm/deny no-infraction, view opponent decklist) must respond promptly over LAN. | <= 200 ms server processing per request at the host; full screen-to-screen interaction latency p95 <= 1 s over local Wi-Fi (2.4/5 GHz) with up to 64 concurrent clients. |
| NFR-03 | Should | Initial client page load over LAN must be lightweight so older/cheaper player phones load it quickly without internet-hosted assets. | Total initial payload (HTML+CSS+JS, no card images) <= 500 KB gzipped; First Contentful Paint <= 2 s and Time-to-Interactive <= 3 s on a mid-range phone over local Wi-Fi. |
| NFR-04 | Should | Standings/round-state updates must propagate to all connected clients quickly after the organizer or players trigger a state change (e.g. round advances). | State change visible on all connected clients within <= 2 s p95 (via push/SSE/WebSocket or <= 3 s polling fallback). |

### 6.7 Scalability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-05 | Must | The system must support the typical tournament size range without functional or performance degradation. | Fully supported: 4 to 64 players (up to 32 concurrent best-of-three matches). All targets in NFR-01/02 hold across this range. |
| NFR-06 | Should | The host must enforce a defined realistic upper bound and degrade gracefully (clear message, no crash) beyond it rather than silently failing. | Hard cap configurable, default 128 players / ~130 concurrent HTTP+socket connections; beyond cap, new joins are rejected with a localized message and the tournament remains stable. |
| NFR-07 | Could | Per-deck historical results store must scale to many tournaments/decks without slowing live tournament operation. | Aggregate deck-vs-field and head-to-head stats query returns in <= 1 s with >= 10,000 stored match records on-device; live tournament write path unaffected. |

### 6.8 Usability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-24 | Must | All primary player actions must be operable one-handed on a phone in portrait, with no horizontal scrolling. | Primary controls (submit result, thumbs up/down, confirm) reachable in the lower 2/3 of a 360x640 dp viewport; no horizontal scroll at 320 dp width. |
| NFR-25 | Must | Touch targets for all interactive controls must meet mobile accessibility sizing to prevent mis-taps when entering results. | >= 48x48 dp per target with >= 8 dp spacing (WCAG 2.1 / Android guidance); result-entry mis-tap rate negligible in usability test. |
| NFR-26 | Must | The client must run on any modern mobile browser with no install and no plugins. | Functional on current and prior-major Chrome (Android), Safari (iOS), Firefox, Samsung Internet; no app install, no PWA-install requirement to use core flows; degrades gracefully without service workers. |

### 6.9 Accessibility

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-27 | Should | UI must meet baseline accessibility for color contrast, text scaling, and screen-reader labeling of result/confirmation controls. | WCAG 2.1 AA contrast (>= 4.5:1 text); supports OS font-scale to 200% without clipping; thumbs up/down and result inputs have non-color, labeled (aria) affordances. |

### 6.10 Localization

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-28 | Must | Full UI (host app and client web interface) available in Italian and English, switchable and defaulting from device locale. | 100% of user-facing strings externalized and translated for it-IT and en-US; default follows browser/OS locale with manual toggle; 0 hardcoded display strings. |
| NFR-29 | Could | Locale-correct formatting and the ability to add further languages without code changes. | Dates/numbers formatted per active locale; new language addable via a resource bundle/JSON file with no recompilation; pluralization handled (ICU/equivalent). |

### 6.11 Portability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-30 | Must | Host distribution and client reach must match the stated model: host as a sideloadable Android APK; client as a plain browser page. | Host installs via APK sideload (no Play Store required) on Android 10+ (API 29+); client requires only a standards-compliant browser, no install, on Android, iOS, and desktop browsers. |

### 6.12 Observability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-31 | Must | Maintain an organizer-visible, append-only audit trail of every result-affecting event for dispute resolution. | Log captures {match, both player submissions, agreement/mismatch, infraction confirmations, suspensions, organizer overrides} with actor + timestamp; viewable in-app; append-only (no in-place edit/delete) for the tournament's lifetime. |
| NFR-32 | Should | Operational/diagnostic logs must be available to the organizer to troubleshoot connectivity and crashes on-device, without internet. | Rolling local log (>= last 1,000 events or 24h) of connections, errors, and state transitions, exportable as a file; redacts no PII because none beyond nickname exists. |

### 6.13 Maintainability

| ID | Pri | Requirement | Target / metric |
|---|---|---|---|
| NFR-37 | Should | Clean separation between the host/native layer, the LAN server, and the served client so each can evolve independently. | Documented module boundaries and a stable internal API contract; pairing engine unit-testable in isolation with >= 80% line coverage on pairing/result-integrity logic. |
| NFR-38 | Should | Swiss-pairing and result-integrity rules must be covered by automated tests to prevent regressions in tournament correctness. | Automated test suite covers pairing edge cases (byes, odd counts, rematbegin avoidance, drops) and the two-sided confirmation/forgery-prevention logic; suite runs in CI in < 5 min. |

## 7. Refinement backlog (gaps found in adversarial review)

These were surfaced by a completeness review of the spec above. They are **not blockers for starting**, but each should be resolved before or during the relevant slice of implementation. Severity is the reviewer's estimate of rework risk if ignored.

| # | Sev | Area | Issue & recommendation |
|---|---|---|---|
| 1 | HIGH | Result reconciliation / disputes | **FR-30/31 and the architecture say a mismatch flips the match to DISPUTED and raises a host alert, but NO resolution workflow is specified. There is no definition of how the host resolves a dispute (force a result? reset both submissions? overwrite?), what UI the host uses, what audit trail is kept, or what the players see while DISPUTED. The transcript ('sospende... all'organizzatore... per eventuali controlli se non ci si trova su qualcosa') implies host adjudication but the spec never closes the loop.** → Add explicit FRs for dispute resolution: (a) host views both submitted results side-by-side; (b) host can set the authoritative result with a mandatory reason note; (c) setting it clears DISPUTED and unblocks the round; (d) the override and original submissions are persisted as an immutable audit record. Define player-facing state text while DISPUTED. |
| 2 | HIGH | Result reconciliation race condition | **FR-29 has both players submit independently, but there is no specified handling for the first-submit/second-submit timing window, for a player editing/resubmitting a different result after their first submission, or for one player submitting while the other never submits. Idempotency keys (architecture) prevent double-apply but do NOT define the state machine for 'one submitted, awaiting second' vs 'one submitted then changed their mind'.** → Specify a per-match result state machine: PENDING -> ONE_SUBMITTED -> {ACCEPTED if match, DISPUTED if mismatch}. Define whether a player may amend a submitted-but-not-yet-reconciled result, and lock submissions once ACCEPTED. Define a host-visible 'awaiting submission' indicator with elapsed time. |
| 3 | HIGH | Round-advance blocking / dropped & absent players | **The round only advances when EVERY match is result-accepted AND both infraction thumbs are in (architecture). A single absent, sleeping, disconnected, or uncooperative player indefinitely blocks the entire round for everyone. Combined with FR-29 dual entry and FR-33 dual infraction confirm, any one missing tap stalls the tournament. No timeout, no host force-advance, no no-show handling is specified.** → Add: (a) host 'force-complete match' authority (assign result, e.g. match loss / 0-2, or intentional draw) bypassing dual entry; (b) no-show / late-player policy (auto game/match loss after configurable timer per MTR); (c) host 'force-advance round' that resolves all incomplete matches per a defined rule. Make the all-confirmed gate overridable by the host. |
| 4 | HIGH | Dropped players mid-round | **Swiss spec says dropped players are removed before pairing the NEXT round and never paired/byed, but the FR/NFR set has NO requirement letting a player drop or the host drop a player, nor what happens to an IN-PROGRESS match when a player drops mid-round, nor whether the opponent gets a win. FR-18 lifecycle and FR-25 cover pairings but not drops.** → Add FRs: player self-drop and host-initiated drop; define mid-round drop = opponent receives match win for current round (per MTR), dropped player excluded from subsequent pairings and from being assigned a bye; clarify dropped player's results already recorded remain in standings/tiebreakers. |
| 5 | HIGH | Tiebreaker correctness | **The Swiss spec names OMW%/GW%/OGW% with a 33% floor and 'own byes excluded from opponents' calculations', but the FR set has NO requirement to compute or display tiebreakers, and the persistence schema (matches, match_results) does not obviously store per-GAME results needed for GW%/OGW%. FR captures match results but Bo3 game-level granularity (2-0 vs 2-1) drives GW%. Risk: standings computed on match points only, producing incorrect rankings and unresolved ties.** → Add explicit FRs to (a) capture per-game scores within each Bo3 match (e.g. 2-1), not just winner; (b) compute standings using the full ordered tiebreaker set (match points, OMW%, GW%, OGW%) with the 33% floor and bye-exclusion rules; (c) display tiebreakers in standings. Verify the DB schema stores game counts. Define draw handling (intentional/unfinished draws = 1 match point each). |
| 6 | HIGH | Byes and odd counts | **FR-24 assigns a bye 'counted as a win' but does not specify the bye's GAME score (MTR treats a bye as a 2-0 / 6 match points but with specific tiebreaker exclusion). The Swiss spec correctly says a player's own byes are excluded from opponents' tiebreaker math, but no FR encodes the bye player's match-point value, its effect on their OWN GW%, or that a bye is not a real opponent for rematch tracking. Also no handling for the bye player needing no result-entry/infraction-confirm step (they would otherwise block the all-confirmed round gate).** → Specify: bye = 2 match-wins worth of match points (3 pts), counts as a match win; bye contributes nothing to opponent lists or OMW%/OGW%; define the bye player's own GW% treatment per MTR; bye matches auto-complete and require no result/infraction entry so they don't block round advance. |
| 7 | HIGH | Decklist-reveal / infraction flow integrity | **FR-32 reveals the opponent's FULL decklist after result acceptance. Two gaps: (1) this permanently exposes every player's exact 75 to every opponent they face, which players may object to (no consent/privacy requirement); (2) the infraction flow (FR-33) has no defined consequence — what does a thumbs-DOWN actually do? The transcript only says it raises a suspension to the host, but the spec text for FR-33 is truncated and the down-path (penalties, game/match loss, re-judging) is undefined. Also: decklists are free text (FR-07/08), so 'infraction' detection is entirely human-eyeball with no validation against the registered list.** → Define the thumbs-down path explicitly: thumbs-down by either player flags the match for host review (suspension), blocks round advance until host adjudicates, and host can apply a defined outcome. Decide whether decklist reveal is acceptable to expose fully or should be gated. Clarify that the app cannot detect deck/list discrepancies automatically (free text) — it only surfaces the list for human comparison. |
| 8 | HIGH | Persistence / crash recovery | **NFR-09/10/11 promise durable commit-before-ack and 100% state-fidelity resume, but the architecture runs the authoritative state in a BACKGROUND ISOLATE with SQLite FFI and broadcasts AFTER a committed transaction. Gaps: (a) no spec for the transient in-flight state — e.g. ONE_SUBMITTED, DISPUTED, pending-infraction — being persisted (only 'accepted results, confirmations, pairings, registrations' are named in NFR-09); if pending-confirmation state is in-memory only, a crash loses it and players must re-tap, contradicting NFR-10's '100% fidelity including pending-confirmation state'. (b) No spec for what happens if the isolate crashes but the UI isolate survives, or vice versa.** → Make NFR-09 explicitly cover ALL match state transitions (single-submission, dispute, infraction pending/done) as durable, not just final accepted results. Add a recovery FR: on restart, reconstruct exact per-match sub-state and re-broadcast snapshot. Specify isolate-crash supervision (restart policy, state reload from DB as single source of truth). |
| 9 | HIGH | Security of result confirmation over open LAN | **The LAN is open and the only auth surface mentioned is allowedOrigins (CSRF/origin lock) + tournament ID + a localStorage session token. There is no authentication binding a session token to a specific player identity beyond first claim. On an open Wi-Fi, any client who knows the tournament ID (broadcast via QR) could (a) join as someone else / claim another player's seat, (b) submit results for matches they aren't in, or (c) confirm/deny infractions on others' behalf. allowedOrigins does not stop a malicious peer on the same LAN. No authorization check that 'the submitter is actually one of the two players in this match' is specified.** → Add security FRs/NFRs: (1) server-side authorization — a result/infraction submission is accepted ONLY from a session token bound to one of the two players in that specific match; reject otherwise. (2) Bind session token to player on first claim and make seat-claiming host-approvable or password/PIN-gated to prevent impersonation. (3) Treat tournament ID as low-entropy (it's on a QR) and do NOT rely on it as a secret for authorization. |
| 10 | MEDIUM | Number of rounds / tournament structure | **The Swiss spec defines rounds-by-attendance and a single-elimination top cut, but NO FR specifies how the number of Swiss rounds is determined (auto from attendance vs host-set), and there is NO requirement for a top-cut / single-elimination bracket at all. The transcript only describes Swiss; the engine spec assumes a top cut exists. This is a scope ambiguity that will cause rework if the owner expects a final bracket.** → Add an FR clarifying round count determination (recommend: auto-suggest from attendance per the table, host-editable). Get an explicit decision on whether v1 includes a top-cut SE bracket or is Swiss-only with final standings (transcript suggests Swiss-only). |
| 11 | MEDIUM | Reconnection of browser clients | **NFR-12 promises idempotent reconnect within 5s and the architecture uses localStorage session tokens + WS snapshot replay. Gaps: (1) no spec for session-token issuance/rotation or what happens if a player clears localStorage / switches browsers / uses a new phone mid-tournament (they could lose their identity and be unable to submit their result); (2) host rotating the tournament ID 'to kick stale clients' (discovery_pairing) would invalidate ALL legitimate sessions — interaction with NFR-10/12 resume is contradictory and undefined; (3) two browser tabs / two devices claiming the same session token is not addressed.** → Specify session recovery: a player must be able to re-identify (re-enter nickname + tournament ID) and reclaim their existing tournament entry/seat after losing localStorage, with host-visible audit. Define single-active-session policy per player (latest wins, or reject duplicate). Clarify that tournament-ID rotation does NOT invalidate already-seated players' sessions. |
| 12 | MEDIUM | Roster lock vs late joiners | **FR-20 locks the roster when the host starts and generates round 1. There is NO requirement for adding a late player after start (common at casual LANs — someone shows up during round 1) or removing a no-show before round 1. Combined with the missing drop flow, mid-event roster changes are entirely unspecified, and they directly affect Swiss pairing math and bye assignment.** → Decide and specify late-add policy: either disallow after start (and say so in UI), or allow host to add a player who enters at standings 0-0 / receives appropriate match-point baseline, with documented tiebreaker implications. Specify pre-start removal of joined-but-absent players. |
| 13 | MEDIUM | Manual pairing override authority & integrity | **FR-25 lets the host override pairings before a round, but there is no requirement that overrides preserve Swiss invariants (no rematch, bye eligibility) or warn on violation, and no audit trail. Combined with dispute overrides and force-advance, the host has broad unconstrained authority with no logging — risk of silent standings corruption and disputes the host cannot defend.** → Specify that manual overrides validate/warn against rematches and double-byes (allow override with explicit confirmation), and that every host override (pairing edit, result set, force-advance, drop) is written to an immutable audit log exportable with the tournament. |
| 14 | MEDIUM | Nickname identity vs accounts persistence | **FR-01/02/04 self-registration + nickname, with players(nickname, token) in the schema, but there is no spec for how a returning player on a new browser/phone re-associates with their stored nickname/decks (FR-12 multiple stored decks implies persistent identity). Token in localStorage is device-local. So 'multiple decks per player' and 'deck history rollup' (FR-09, NFR-07) assume durable player identity that the join flow (just enter nickname) cannot reliably reconstruct. Two people could also pick the same nickname across sessions despite FR-03 uniqueness-within-app.** → Clarify the identity model: is a 'player' a durable account (needs a recovery credential/PIN to log back in and see their decks/history) or ephemeral per-tournament? The deck-history feature (FR-09/NFR-07) requires durable identity; reconcile this with the credential-less join flow. |
| 15 | MEDIUM | Decklist validation realism | **FR-10/11 validate >=60 maindeck and <=15 sideboard by 'counting cards' in FREE TEXT (FR-07/08). Parsing free-text decklists (quantities, card-name typos, 'SB:' markers, multi-format like '4 Lightning Bolt' vs 'Lightning Bolt x4') is non-trivial and the parsing rules are unspecified. Risk: validation either rejects valid lists or accepts invalid ones, and the deck-name rollup (FR-09) needs canonical card names it cannot reliably extract.** → Specify the decklist text format/grammar the parser accepts (e.g. 'N Cardname' per line, blank line or 'Sideboard' header separates), and define behavior on unparseable lines (warn but allow? block?). For v1, consider counting only (sum of leading integers) and treating card-name normalization as best-effort. |
| 16 | MEDIUM | Standings/round-state visibility & intentional draws | **FR-26 covers live pairings view and there is implied standings, but the Bo3 match structure spec mentions match results that can be draws, and there is no FR for capturing an intentional draw or an unfinished/time-limited match (no round timer is specified at all). LAN casual rounds often need a time limit + turns procedure; absence means matches can run indefinitely, compounding the round-advance blocking issue.** → Decide whether a round timer is in scope. At minimum allow a match to be recorded as a draw (1-1-1 games or 0-0 intentional draw = 1 match point each) and ensure standings/tiebreakers handle draws. If no timer, document that round length is socially managed and rely on host force-advance. |
| 17 | LOW | Optional card-image feature | **Card images are explicitly OUT of v1 (architecture, transcript voice note 2: 'l'utilizzo delle immagini... la complessità diventa molto più grande'). No gap in scoping it out, BUT NFR-03/14 (<=500KB payload, zero external requests, offline-only) means a FUTURE image feature would require bundling card images IN the APK or serving them from the host — which conflicts with the lightweight/offline constraints and would need a local card database. This is an unflagged architectural dead-end if images are added later.** → Note explicitly that any future card-image feature must source images offline (bundled or host-cached set/scryfall-bulk import done while online), since NFR-13/14 forbid runtime external calls. No v1 action needed; document the constraint so the v1 data model leaves room (e.g. store card names normalized) and the owner isn't surprised later. |

## 8. Decisions needed from you (product owner)

The review raised these questions that only you can answer. They mostly concern *policy*, not engineering, and they shape several requirements above. Answering them turns the relevant **Should/Could** items into concrete **Must** behavior.

1. ✅ **Resolved (2026-06-14): durable identity.** A 'player' is a durable cross-tournament account with a stable id, persisted on the host's database, so saved decks and per-deck win/loss history accumulate across events. The app keeps a tournament history (with dates) and lifetime statistics. *Implication being built:* returning players re-identify (nickname + a recovery credential/PIN) to reclaim their durable record on a new device; the stats engine (`lib/shared/stats.dart`) and a local SQLite DB back the history/analytics. *(Original question retained for context: is a 'player' a durable cross-tournament account, or ephemeral per tournament? The deck-performance database only works with durable identity, but the join flow is otherwise credential-less.)*
2. Is v1 Swiss-only with final standings, or must it also run a single-elimination top cut after Swiss? The transcript describes only Swiss; the engine spec assumes a top cut.
3. Should the number of Swiss rounds be auto-determined from attendance (per the MTR table) or set manually by the host each event?
4. When two players submit conflicting results, how do you want the host to resolve it — pick a winner, force both to re-enter, or assign a default (e.g. double game loss)? And should the original conflicting submissions be permanently logged?
5. What should a thumbs-DOWN (infraction reported) actually do? Just alert you as host for manual handling, or trigger a defined penalty (game loss / match loss)? Who decides the penalty?
6. Are you comfortable that every player's FULL 75-card list is permanently revealed to each opponent they play (and potentially screenshot)? Or should reveal be limited / consent-based?
7. How should the app handle a player who drops or disappears mid-round — does their current opponent automatically get the win, and can a late arrival be added after round 1 has started?
8. Do you want a round timer / time limit (with end-of-round turns) like sanctioned events, or will round length be managed socially and you just force-advance when ready?
9. On the open LAN, how much do you trust the player pool? Should claiming a player seat require a PIN/host approval to stop someone from impersonating another player or submitting results for a match they aren't in? (Currently only the tournament ID + a device token gate this, and the ID is on the public QR.)
10. What is the policy for a player who loses their browser session (cleared cache / new phone) mid-tournament — can they re-enter their nickname and reclaim their seat and pending result, and do you want to approve that as host?

## 9. Implementation status (2026-06-14)

Built and verified on the emulator (debug build, all 31 Dart tests green, `flutter analyze` clean):

- **Core flow** — host creates an event → QR/code lobby → players join from a browser (REST + WS) → Swiss round 1 → dual independent result entry & reconciliation → post-match decklist reveal → thumbs-up/down infraction confirm → round gating → standings (OMW%/GW%). (FR-01–47, NFR-08/09/10 foreground service + crash-resume.)
- **FR-51 Stop hosting** — the foreground-service notification carries a *Stop hosting* action that pauses hosting non-destructively; *Resume hosting* restarts it; *End event* archives. Verified via the notification shade + `dumpsys notification` (action `[0] "Stop hosting"`).
- **FR-52 Tournament history** — finished events are archived to durable storage; the **Events** tab lists them (date · size · 🏆 champion) and opens a detail screen (final standings, roster + decklists, per-round results); **delete** removes one and recomputes stats. **Decks** and **Profile** show real per-deck records and lifetime stats from the same `StatsEngine` read model. All four tabs show honest empty states with **no mock/sample data** (the previous placeholders were removed).
- **Durable owner identity** — the device has a persistent `ownerPlayerId` (the host's durable player) that survives event end and backs the Decks/Profile/history aggregation (resolves §8 Q1).

Not yet built / out of v1: top-cut bracket (Q2), explicit late-join/manual-pairing UIs (FR-25/late-add), localisation (NFR-28), Drift/SQLite migration (currently a single JSON blob via `FilePersistence` — schema/ACID NFR-33/35 still to migrate), and the open-LAN anti-impersonation hardening (Q9).

---

*Generated from the requirements-analysis workflow (2026-06-13). Edit freely — this file is the human-owned spec, not generated output that will be overwritten.*
