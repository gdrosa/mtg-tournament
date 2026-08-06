/// Authoritative server-side controller: durable players/decks, the active
/// tournament engine, sessions, and per-viewer snapshot building + broadcast.
///
/// PURE DART (no Flutter imports) so it runs inside the host app AND standalone
/// via `dart run bin/dev_server.dart` for headless testing on Windows.
library;

import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../shared/cards.dart';
import '../shared/deck_revision.dart';
import '../shared/hosting.dart';
import '../shared/models.dart';
import '../shared/questionnaire.dart';
import '../shared/stats.dart';
import '../shared/stats_facts.dart';
import '../shared/stats_service.dart';
import '../shared/tournament_engine.dart';
import 'persistence.dart';

const _uuid = Uuid();

/// Version of the local save format.
///
/// 1 — implicit, any save without this marker: no deck revisions, no
///     questionnaires, no aliases. Loading one back-fills revisions.
/// 2 — deck revisions, questionnaires, nickname aliases, tournament
///     format/series.
///
/// Reading is always backward-compatible; the marker exists so an import can
/// refuse a file from a *newer* app rather than silently dropping fields.
const int kSaveSchemaVersion = 2;

/// Semantic limits keep one browser from making every viewer snapshot too
/// large to deliver. They apply to LAN and Online so both transports behave
/// identically.
const int maxNicknameLength = 64;
const int maxTournamentNameLength = 120;
const int maxDeckNameLength = 120;
const int maxMainboardLength = 32 * 1024;
const int maxSideboardLength = 16 * 1024;
const int maxDecksPerPlayer = 64;
const int maxTournamentPlayers = 128;
const int maxStoredPlayers = 4096;

/// A connected client (WebSocket) and the session it is viewing as.
class Connection {
  String? token;
  final void Function(String message) send;
  Connection(this.send, {this.token});
}

class ServerController {
  // ---- durable registries (persist across tournaments) ----
  final Map<String, Player> players = {}; // playerId -> Player
  final Map<String, Deck> decks = {}; // deckId -> Deck
  final Map<String, CardInfo> cardCatalog = {}; // scryfall id -> card metadata
  final Map<String, String> _tokenToPlayer = {}; // sessionToken -> playerId

  /// Immutable decklists as played, keyed by revision id. Never mutated and
  /// never dropped while any tournament entry references one — this is what
  /// stops editing a deck from rewriting last season's results.
  final Map<String, DeckRevision> deckRevisions = {};

  /// Nicknames a player has used before, newest last. Used **only** to suggest
  /// candidate matches when importing someone else's data; two players sharing
  /// a nickname are never merged on that basis.
  final Map<String, List<String>> playerAliases = {};

  /// Optional post-match questionnaires, keyed by [surveyKey]. Raw answers are
  /// private: they never enter a player-facing snapshot beyond the answering
  /// player's own copy, and never enter a shared export.
  final Map<String, MatchSurvey> surveys = {};

  // ---- durable device-owner identity (this phone's player) ----
  // Distinct from [hostPlayerId] (the host of the *active* event): the owner is
  // who the device belongs to and accumulates decks/history across events. It
  // is never cleared when an event ends. The two coincide in normal use.
  String? ownerPlayerId;
  String? ownerToken;

  // ---- finished-tournament archive (the history/statistics read model) ----
  final List<TournamentEngine> archive = [];

  // ---- active tournament ----
  TournamentEngine? engine;
  String? joinCode; // short human code for the active event
  String? hostPlayerId;
  HostingMode? hostingMode;

  // ---- live connections ----
  final Set<Connection> _connections = {};

  final Random _rng;
  void Function()? onChange; // hook so the host UI can rebuild
  // Fired after any deck is saved (organizer OR a participant via /api/deck) with
  // the saved deck's id, so the Flutter host can resolve+cache its card images in
  // the background. Null in headless/test runs (pure Dart, no Scryfall).
  void Function(String deckId)? onDeckSaved;
  Persistence? store; // durable crash-resume storage (optional)

  /// Injected clock so questionnaire windows and revision timestamps are
  /// deterministic under test.
  final DateTime Function() clock;

  ServerController({Random? rng, DateTime Function()? clock})
    : _rng = rng ?? Random(),
      clock = clock ?? DateTime.now;

  // ========================================================================
  // Identity / decks (durable)
  // ========================================================================

  /// Resolve a session: reuse the player bound to [token], else create a new
  /// durable player for [nickname]. Returns the (token, playerId).
  ({String token, String playerId}) resolveSession(
    String nickname,
    String? token,
  ) {
    final normalizedNickname = nickname.trim();
    if (normalizedNickname.isEmpty) throw EngineError('Nickname required.');
    if (normalizedNickname.length > maxNicknameLength) {
      throw EngineError(
        'Nickname must be $maxNicknameLength characters or fewer.',
      );
    }
    if (token != null && _tokenToPlayer.containsKey(token)) {
      final pid = _tokenToPlayer[token]!;
      // allow a returning player to update their display nickname
      final previous = players[pid]?.nickname;
      if (previous != null && previous != normalizedNickname) {
        // Keep the old name so history stays searchable under it and imports
        // can *suggest* (never assume) that this is the same person.
        final list = playerAliases.putIfAbsent(pid, () => []);
        list.remove(previous);
        list.add(previous);
      }
      players[pid] = Player(id: pid, nickname: normalizedNickname);
      return (token: token, playerId: pid);
    }
    if (players.length >= maxStoredPlayers) {
      throw EngineError('This device has reached its saved-player limit.');
    }
    final pid = _uuid.v4();
    // Never adopt an unknown client-supplied bearer token. Besides allowing a
    // caller to choose credentials, that becomes especially dangerous once the
    // player API is internet-facing through the online relay.
    final newToken = _uuid.v4();
    players[pid] = Player(id: pid, nickname: normalizedNickname);
    _tokenToPlayer[newToken] = pid;
    return (token: newToken, playerId: pid);
  }

  String? playerIdForToken(String? token) =>
      token == null ? null : _tokenToPlayer[token];

  /// Ensure this device has a durable owner identity, (re)binding it to
  /// [nickname]. Returns the owner session. Does NOT persist on its own — the
  /// caller persists once the surrounding mutation (create event / save deck /
  /// edit profile) is complete, via [persistAndNotify].
  ({String token, String playerId}) ensureOwner(String nickname) {
    final s = resolveSession(nickname, ownerToken);
    ownerToken = s.token;
    ownerPlayerId = s.playerId;
    return s;
  }

  /// The durable owner [Player], if one has been established.
  Player? get owner => ownerPlayerId == null ? null : players[ownerPlayerId];

  /// Persist current state and notify clients/UI. Used by callers that mutate
  /// durable registries (e.g. standalone deck registration) outside the
  /// tournament command path.
  void persistAndNotify() => _changed();

  Deck saveDeck({
    required String ownerId,
    String? deckId,
    required String name,
    required String mainboard,
    required String sideboard,
    String? archetype,
  }) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) throw EngineError('Deck name required.');
    if (normalizedName.length > maxDeckNameLength) {
      throw EngineError(
        'Deck name must be $maxDeckNameLength characters or fewer.',
      );
    }
    if (mainboard.length > maxMainboardLength) {
      throw EngineError('Maindeck text is too long.');
    }
    if (sideboard.length > maxSideboardLength) {
      throw EngineError('Sideboard text is too long.');
    }
    if (deckId == null && decksOf(ownerId).length >= maxDecksPerPlayer) {
      throw EngineError('A player can save at most $maxDecksPerPlayer decks.');
    }
    final id = deckId ?? _uuid.v4();
    _requireEditableDeck(id);
    final deck = Deck(
      id: id,
      ownerId: ownerId,
      name: normalizedName,
      // Null means "leave it alone" — the browser client never sends one and
      // must not blank the archetype the organizer set on the phone.
      archetype: (archetype ?? decks[id]?.archetype ?? '').trim(),
      mainboardText: mainboard,
      sideboardText: sideboard,
    );
    decks[id] = deck;
    _changed(); // persist + broadcast (esp. participant decks via /api/deck)
    onDeckSaved?.call(id); // host resolves + caches the card images off-thread
    return deck;
  }

  List<Deck> decksOf(String playerId) =>
      decks.values.where((d) => d.ownerId == playerId).toList();

  void _requireEditableDeck(String deckId) {
    final active = engine;
    if (active?.status == TournamentStatus.running &&
        active!.entries.any((entry) => entry.deckId == deckId)) {
      throw EngineError('Decks are locked once the tournament starts.');
    }
  }

  /// Permanently delete a deck. Refused (returns false) if it is entered in the
  /// active tournament — removing it would corrupt the live pairings/decklist
  /// view. Past archived results keep their own deck-name copies, so deleting a
  /// deck used only in history is safe.
  bool deleteDeck(String deckId) {
    if (engine?.entries.any((e) => e.deckId == deckId) ?? false) return false;
    if (decks.remove(deckId) == null) return false;
    _changed();
    return true;
  }

  // ---- immutable deck revisions -----------------------------------------

  /// Freeze [deck] as it stands, reusing an identical existing revision.
  ///
  /// Revision ids are content-addressed, so re-entering an unchanged deck does
  /// not pile up duplicates, and two devices that hold the same list agree on
  /// the same id (which is what makes importing a shared tournament idempotent).
  DeckRevision _ensureRevision(
    Deck deck, {
    required DateTime at,
    bool migrated = false,
  }) {
    final ordinal =
        deckRevisions.values.where((r) => r.deckId == deck.id).length + 1;
    final candidate = DeckRevision.of(
      deck,
      revision: ordinal,
      at: at,
      migrated: migrated,
    );
    final existing = deckRevisions[candidate.id];
    if (existing != null) return existing;
    deckRevisions[candidate.id] = candidate;
    return candidate;
  }

  /// The revision an entry played, or null when the deck predates revisions and
  /// could not be reconstructed (its deck was deleted).
  DeckRevision? revisionOf(Entry entry) =>
      entry.deckRevisionId == null ? null : deckRevisions[entry.deckRevisionId];

  /// Every revision of [deckId], oldest first.
  List<DeckRevision> revisionsOf(String deckId) => [
    for (final r in deckRevisions.values)
      if (r.deckId == deckId) r,
  ]..sort((a, b) => a.revision.compareTo(b.revision));

  /// Back-fill revisions for saves written before they existed, and for any
  /// entry whose revision went missing. The deck's *current* list is the best
  /// available evidence, so the synthesized revision is flagged [migrated] and
  /// every screen that shows it says so.
  int migrateMissingRevisions() {
    var filled = 0;
    for (final e in [?engine, ...archive]) {
      for (final entry in e.entries) {
        if (entry.deckRevisionId != null &&
            deckRevisions.containsKey(entry.deckRevisionId)) {
          continue;
        }
        final deck = decks[entry.deckId];
        if (deck == null) continue; // deck deleted: leave it honestly unknown
        entry.deckRevisionId = _ensureRevision(
          deck,
          at: e.createdAt,
          migrated: true,
        ).id;
        filled++;
      }
    }
    return filled;
  }

  // ---- post-match questionnaire ------------------------------------------

  /// Open questionnaires for any match in the current round that has just been
  /// confirmed. Idempotent, and never touches the match itself.
  void _openSurveysForConfirmedMatches() {
    final e = engine;
    if (e == null || e.rounds.isEmpty) return;
    final now = clock();
    for (final m in e.currentRound.matches) {
      if (m.isBye || m.state != MatchState.confirmed) continue;
      final key = surveyKey(e.id, m.id);
      if (surveys.containsKey(key)) continue;
      final s = MatchSurvey.open(tournamentId: e.id, match: m, now: now);
      if (s != null) surveys[key] = s;
    }
  }

  void _closeSurveysBeforeRound() {
    final e = engine;
    if (e == null || e.rounds.isEmpty) return;
    for (final m in e.currentRound.matches) {
      surveys[surveyKey(e.id, m.id)]?.closed = true;
    }
  }

  /// The open questionnaire for [playerId]'s current match, if any.
  MatchSurvey? surveyFor(String playerId) {
    final e = engine;
    if (e == null || e.rounds.isEmpty) return null;
    final m = e.currentRound.matchFor(playerId);
    if (m == null) return null;
    return surveys[surveyKey(e.id, m.id)];
  }

  /// Record a player's questionnaire answers. Throws [EngineError] when there
  /// is nothing to answer; the result of the match is never affected.
  void submitSurvey({
    required String playerId,
    required String matchId,
    required List<GameOutcome> games,
    required List<MulliganCount> mulligans,
    TriState onThePlayGame1 = TriState.unknown,
    TriState sideboarded = TriState.unknown,
  }) {
    final e = _requireEngine();
    final survey = surveys[surveyKey(e.id, matchId)];
    if (survey == null) {
      throw EngineError('No questionnaire for that match.');
    }
    try {
      survey.submit(
        SurveyResponse(
          playerId: playerId,
          submittedAt: clock(),
          games: games,
          mulligans: mulligans,
          onThePlayGame1: onThePlayGame1,
          sideboarded: sideboarded,
        ),
        clock(),
      );
    } on SurveyError catch (err) {
      throw EngineError(err.message);
    }
    _changed();
  }

  /// Host-only: questionnaires for [tournamentId] whose two accounts disagree.
  /// Conflicts are preserved, never resolved — the confirmed result stands.
  List<({String matchId, List<SurveyConflict> conflicts})> surveyConflicts(
    String tournamentId,
  ) => [
    for (final s in surveys.values)
      if (s.tournamentId == tournamentId && s.conflicts.isNotEmpty)
        (matchId: s.matchId, conflicts: s.conflicts),
  ];

  // ---- card catalog (Scryfall metadata for the card-format editor/reveal) ----

  CardInfo? card(String id) => cardCatalog[id];
  String? cardName(String id) => cardCatalog[id]?.name;

  /// Register/refresh Scryfall card metadata. Does NOT persist on its own — the
  /// caller persists once the surrounding edit completes (via [persistAndNotify]
  /// or [setDeckCards], which persists).
  void registerCards(Iterable<CardInfo> cards) {
    for (final c in cards) {
      cardCatalog[c.id] = c;
    }
  }

  /// Replace a deck's structured card lists, then persist + broadcast. Used by
  /// the deck editor.
  ///
  /// By default the free-text lists are regenerated from [main]/[side] to stay
  /// in sync. Pass [keepText] = true to preserve the existing text instead — the
  /// resolver uses this when a Scryfall fetch only partially succeeded, so the
  /// user's original typed decklist is never clobbered with the resolved subset.
  Deck setDeckCards({
    required String deckId,
    required List<DeckCardEntry> main,
    required List<DeckCardEntry> side,
    bool keepText = false,
  }) {
    final d = decks[deckId];
    if (d == null) throw EngineError('Unknown deck.');
    _requireEditableDeck(deckId);
    final updated = d.copyWith(
      mainCards: main,
      sideCards: side,
      mainboardText: keepText
          ? d.mainboardText
          : renderDecklist(main, cardName),
      sideboardText: keepText
          ? d.sideboardText
          : renderDecklist(side, cardName),
    );
    decks[deckId] = updated;
    _changed();
    return updated;
  }

  // ========================================================================
  // Tournament lifecycle (host authority)
  // ========================================================================

  String createTournament({
    required String name,
    required String hostPlayerId,
    HostingMode mode = HostingMode.lan,
    TournamentKind kind = TournamentKind.swiss,
    String format = '',
    String series = '',
    int rounds = 0,
    int roundMinutes = 0,
  }) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) throw EngineError('Tournament name required.');
    if (normalizedName.length > maxTournamentNameLength) {
      throw EngineError(
        'Tournament name must be $maxTournamentNameLength characters or fewer.',
      );
    }
    this.hostPlayerId = hostPlayerId;
    hostingMode = mode;
    engine = TournamentEngine(
      id: _uuid.v4(),
      name: normalizedName,
      createdAt: clock(),
      kind: kind,
      format: format.trim(),
      series: series.trim(),
      rng: _rng,
      clock: clock,
    );
    if (roundMinutes > 0) engine!.setRoundMinutes(roundMinutes);
    if (rounds > 0 && kind == TournamentKind.swiss) {
      engine!.setPlannedRounds(rounds);
    }
    joinCode = _shortCode();
    _changed();
    return joinCode!;
  }

  String _shortCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(
      4,
      (_) => alphabet[_rng.nextInt(alphabet.length)],
    ).join();
  }

  /// A player (or the host) joins the active tournament with a chosen deck.
  void joinTournament({required String playerId, required String deckId}) {
    final e = _requireEngine();
    if (e.status != TournamentStatus.lobby) {
      throw EngineError('The tournament has already started.');
    }
    final deck = decks[deckId];
    if (deck == null) throw EngineError('Unknown deck.');
    // A player may only enter with a deck they own — mirrors the /api/deck guard,
    // so no one can seat themselves with (and later reveal) another player's list.
    if (deck.ownerId != playerId) throw EngineError('Not your deck.');
    if (e.entries.length >= maxTournamentPlayers) {
      throw EngineError(
        'This tournament is limited to $maxTournamentPlayers players.',
      );
    }
    e.addEntry(playerId, deckId);
    // Freeze the list as entered. From here the player may edit the deck all
    // they like; this event keeps the 75 they actually registered.
    e.entryOf(playerId)!.deckRevisionId = _ensureRevision(deck, at: clock()).id;
    _changed();
  }

  void startTournament() {
    _requireEngine().start();
    _changed();
  }

  void advanceRound() {
    // A new round makes the previous round's questionnaires stale. Closing
    // them is the only interaction between the two — an unanswered survey has
    // never gated anything.
    _closeSurveysBeforeRound();
    _requireEngine().advanceRound();
    _changed();
  }

  /// Host overrides for how the event is run. None of them touches a played
  /// match: they change how many rounds remain, who is seated where in the
  /// round about to be played, and the clock on the wall.
  void setPlannedRounds(int rounds) {
    _requireEngine().setPlannedRounds(rounds);
    _changed();
  }

  void setRoundMinutes(int minutes) {
    _requireEngine().setRoundMinutes(minutes);
    _changed();
  }

  void startRoundTimer() {
    _requireEngine().startRoundTimer();
    _changed();
  }

  void stopRoundTimer() {
    _requireEngine().stopRoundTimer();
    _changed();
  }

  void swapPairing(String playerA, String playerB) {
    _requireEngine().swapPairing(playerA, playerB);
    _changed();
  }

  void hostResolve(String matchId, int p1Wins, int p2Wins, {String? note}) {
    _requireEngine().hostResolve(
      matchId,
      GameScore(p1Wins, p2Wins),
      note: note,
    );
    _changed();
  }

  void dropPlayer(String playerId) {
    _requireEngine().dropPlayer(playerId);
    _changed();
  }

  /// Disqualify one or both players in a match under review.
  void disqualify(String matchId, List<String> playerIds, {String? note}) {
    _requireEngine().disqualify(matchId, playerIds, note: note);
    _changed();
  }

  // ========================================================================
  // Player commands (during a round)
  // ========================================================================

  /// Submit a Bo3 result from [playerId]'s own perspective (games I won vs my
  /// opponent won); the controller orients it to the canonical (p1,p2).
  void submitResult({
    required String playerId,
    required String matchId,
    required int mineWon,
    required int oppWon,
    int draws = 0,
  }) {
    final e = _requireEngine();
    final m = _findMatch(e, matchId);
    final isP1 = m.p1Id == playerId;
    final score = isP1
        ? GameScore(mineWon, oppWon, draws)
        : GameScore(oppWon, mineWon, draws);
    e.submitResult(matchId, playerId, score);
    _changed();
  }

  void confirmInfraction({
    required String playerId,
    required String matchId,
    required bool ok,
  }) {
    _requireEngine().confirmNoInfraction(matchId, playerId, ok);
    _changed();
  }

  // ========================================================================
  // Snapshots + broadcast
  // ========================================================================

  void addConnection(Connection c) {
    _connections.add(c);
    c.send(snapshotJsonFor(c.token));
  }

  void removeConnection(Connection c) => _connections.remove(c);

  void _changed() {
    // A match may have just been confirmed; offer its questionnaire in the very
    // same snapshot, so players see it without waiting for another event.
    _openSurveysForConfirmedMatches();
    _persist(); // persist-then-push: durable before any client sees it
    for (final c in _connections) {
      c.send(snapshotJsonFor(c.token));
    }
    onChange?.call();
  }

  void _persist() {
    final s = store;
    if (s != null) s.save(jsonEncode(toJson()));
  }

  // ---- crash-resume (de)serialization -----------------------------------

  Map<String, dynamic> toJson() => {
    'schema': kSaveSchemaVersion,
    'players': players.values.map((p) => p.toJson()).toList(),
    'aliases': playerAliases,
    'decks': decks.values.map((d) => d.toJson()).toList(),
    'revisions': deckRevisions.values.map((r) => r.toJson()).toList(),
    'surveys': surveys.values.map((s) => s.toJson()).toList(),
    'cards': cardCatalog.values.map((c) => c.toJson()).toList(),
    'tokens': _tokenToPlayer,
    'ownerPlayerId': ownerPlayerId,
    'ownerToken': ownerToken,
    'hostPlayerId': hostPlayerId,
    'joinCode': joinCode,
    'hostingMode': hostingMode?.name,
    'engine': engine?.toJson(),
    'archive': archive.map((e) => e.toJson()).toList(),
  };

  /// Serialize the full durable state as a JSON string — the exact blob written
  /// to local storage, reused as the unit of Google Drive cloud backup.
  String exportJson() => jsonEncode(toJson());

  /// Replace all durable state from a cloud/backup blob, then persist locally and
  /// broadcast. Returns false (state untouched) if the blob can't be parsed.
  bool importJson(String raw) {
    try {
      _applyJson(jsonDecode(raw) as Map);
    } catch (_) {
      return false;
    }
    _changed(); // persist locally + push to clients + rebuild UI
    return true;
  }

  /// Load durable state from [store] (if any). Keeps the durable registries
  /// (players/decks/history) even across tournaments.
  void loadFromStore() {
    final raw = store?.load();
    if (raw == null) return;
    _applyJson(jsonDecode(raw) as Map);
  }

  void _applyJson(Map j) {
    // Decode into temporary collections first. A corrupt or incompatible
    // backup must never leave the live controller half-cleared.
    final nextPlayers = <String, Player>{};
    final nextDecks = <String, Deck>{};
    final nextCards = <String, CardInfo>{};
    final nextTokens = <String, String>{};
    final nextArchive = <TournamentEngine>[];
    final nextRevisions = <String, DeckRevision>{};
    final nextSurveys = <String, MatchSurvey>{};
    final nextAliases = <String, List<String>>{};
    for (final p in (j['players'] as List)) {
      final pl = Player.fromJson(p as Map);
      nextPlayers[pl.id] = pl;
    }
    for (final d in (j['decks'] as List)) {
      final dk = Deck.fromJson(d as Map);
      nextDecks[dk.id] = dk;
    }
    // Absent in pre-0.0.4 saves; [migrateMissingRevisions] fills the gap below.
    for (final r in (j['revisions'] as List? ?? const [])) {
      final rev = DeckRevision.fromJson(r as Map);
      nextRevisions[rev.id] = rev;
    }
    for (final s in (j['surveys'] as List? ?? const [])) {
      final survey = MatchSurvey.fromJson(s as Map);
      nextSurveys[survey.key] = survey;
    }
    (j['aliases'] as Map? ?? const {}).forEach((k, v) {
      nextAliases[k as String] = [for (final a in (v as List)) a as String];
    });
    for (final c in (j['cards'] as List? ?? const [])) {
      final ci = CardInfo.fromJson(c as Map);
      nextCards[ci.id] = ci;
    }
    // Absent in a shared export, which strips session credentials.
    (j['tokens'] as Map? ?? const {}).forEach(
      (k, v) => nextTokens[k as String] = v as String,
    );
    final nextOwnerPlayerId = j['ownerPlayerId'] as String?;
    final nextOwnerToken = j['ownerToken'] as String?;
    final nextHostPlayerId = j['hostPlayerId'] as String?;
    final nextJoinCode = j['joinCode'] as String?;
    final modeName = j['hostingMode'] as String?;
    final nextHostingMode = nextJoinCode == null
        ? null
        : modeName == null
        ? HostingMode
              .lan // backward-compatible active LAN saves
        : HostingMode.values.byName(modeName);
    final nextEngine = j['engine'] == null
        ? null
        : TournamentEngine.fromJson(
            j['engine'] as Map,
            rng: _rng,
            clock: clock,
          );
    for (final a in (j['archive'] as List? ?? const [])) {
      nextArchive.add(
        TournamentEngine.fromJson(a as Map, rng: _rng, clock: clock),
      );
    }

    players
      ..clear()
      ..addAll(nextPlayers);
    decks
      ..clear()
      ..addAll(nextDecks);
    cardCatalog
      ..clear()
      ..addAll(nextCards);
    _tokenToPlayer
      ..clear()
      ..addAll(nextTokens);
    archive
      ..clear()
      ..addAll(nextArchive);
    deckRevisions
      ..clear()
      ..addAll(nextRevisions);
    surveys
      ..clear()
      ..addAll(nextSurveys);
    playerAliases
      ..clear()
      ..addAll(nextAliases);
    ownerPlayerId = nextOwnerPlayerId;
    ownerToken = nextOwnerToken;
    hostPlayerId = nextHostPlayerId;
    joinCode = nextJoinCode;
    hostingMode = nextHostingMode;
    engine = nextEngine;

    // Schema migration, run last because it needs decks + archive in place.
    migrateMissingRevisions();
  }

  /// End the current event. A tournament that actually started (has at least
  /// one round) is moved into the [archive] for history/statistics; a
  /// never-started lobby is simply discarded. Durable players/decks are kept.
  void clearTournament() {
    final e = engine;
    if (e != null && e.rounds.isNotEmpty && !archive.any((a) => a.id == e.id)) {
      e.finish(); // mark finished so history reflects a closed event
      archive.add(e);
    }
    engine = null;
    joinCode = null;
    hostPlayerId = null;
    hostingMode = null;
    _changed();
  }

  /// Permanently delete an archived tournament from history.
  void deleteArchived(String tournamentId) {
    archive.removeWhere((a) => a.id == tournamentId);
    _changed();
  }

  /// Look up an archived (or the active) tournament engine by id.
  TournamentEngine? tournamentById(String id) {
    if (engine?.id == id) return engine;
    for (final a in archive) {
      if (a.id == id) return a;
    }
    return null;
  }

  // ========================================================================
  // History / statistics (read model for the Events/Decks/Profile screens)
  // ========================================================================

  /// The archived tournaments as [TournamentHistoryEntry] rows the
  /// [StatsEngine] consumes (keyed to the named deck each player brought).
  List<TournamentHistoryEntry> historyEntries() => [
    for (final e in archive)
      TournamentHistoryEntry(
        tournamentId: e.id,
        name: e.name,
        date: e.createdAt,
        records: e.matchRecords,
        deckByPlayer: {for (final en in e.entries) en.playerId: en.deckId},
      ),
  ];

  /// Cross-tournament statistics engine over the current [archive].
  StatsEngine get stats => StatsEngine(historyEntries());

  /// The normalized fact table: every settled match across history (and, by
  /// default, the event in progress), tagged with the exact deck revision,
  /// archetype, format and series it was played under.
  List<MatchFact> matchFacts({bool includeActive = true}) => [
    for (final e in [...archive, if (includeActive && engine != null) engine!])
      ..._factsOf(e),
  ];

  Iterable<MatchFact> _factsOf(TournamentEngine e) sync* {
    SideFact sideOf(String playerId) {
      final entry = e.entryOf(playerId);
      final deck = entry == null ? null : decks[entry.deckId];
      final revision = entry == null ? null : revisionOf(entry);
      return SideFact(
        playerId: playerId,
        deckId: entry?.deckId ?? '',
        // The revision is the truth about what was played; the live deck is
        // only a fallback for history that predates revisions.
        revisionId: revision?.id ?? '',
        deckName: revision?.name ?? deck?.name ?? '',
        archetype: revision?.archetype ?? deck?.archetype ?? '',
        dropped: entry?.dropped ?? false,
      );
    }

    for (final played in e.playedMatches) {
      final m = played.match;
      yield MatchFact(
        tournamentId: e.id,
        tournamentName: e.name,
        date: e.createdAt,
        format: e.format,
        series: e.series,
        round: played.round,
        matchId: m.id,
        p1: sideOf(m.p1Id),
        p2: m.isBye ? null : sideOf(m.p2Id!),
        score: m.accepted ?? const GameScore(2, 0),
        adjudicated: m.adjudicated,
        disputed: m.disputed,
      );
    }
  }

  /// Typed statistics queries over [matchFacts]. Build one per screen; every
  /// report it returns is plain data.
  StatsService get statistics =>
      StatsService(matchFacts(), revisions: deckRevisions);

  /// Players who dropped from [tournamentId] — the piece a fact table cannot
  /// carry, since a drop is a property of the entry, not of a match.
  List<String> droppedIn(String tournamentId) {
    final e = tournamentById(tournamentId);
    if (e == null) return const [];
    return [
      for (final entry in e.entries)
        if (entry.dropped) entry.playerId,
    ];
  }

  /// Full entrant roster of [tournamentId], including players whose matches are
  /// all still unresolved.
  List<String> rosterOf(String tournamentId) =>
      tournamentById(tournamentId)?.allPlayerIds ?? const [];

  /// A full read-only view of one tournament for the history detail screen:
  /// final standings, the roster with decklists, and every round's results.
  Map<String, dynamic> historyDetail(TournamentEngine e) => {
    'id': e.id,
    'name': e.name,
    'date': e.createdAt.toIso8601String(),
    'format': e.format,
    'series': e.series,
    'status': e.status.name,
    'roundCount': e.rounds.length,
    'playerCount': e.entries.length,
    'standings': _standingsArray(e),
    'players': [
      for (final x in e.entries)
        {
          'playerId': x.playerId,
          'nickname': players[x.playerId]?.nickname ?? '?',
          'deckName': revisionOf(x)?.name ?? decks[x.deckId]?.name ?? '?',
          'dropped': x.dropped,
          'record': _recordString(e, x.playerId),
          // The list registered for this event, never the edited-since deck.
          'main':
              revisionOf(x)?.mainboardText ??
              decks[x.deckId]?.mainboardText ??
              '',
          'side':
              revisionOf(x)?.sideboardText ??
              decks[x.deckId]?.sideboardText ??
              '',
          'revisionId': revisionOf(x)?.id,
          'listIsReconstructed': revisionOf(x)?.migrated ?? true,
        },
    ],
    'rounds': [
      for (final r in e.rounds)
        {
          'number': r.number,
          'matches': [
            for (final m in r.matches)
              {
                'p1': players[m.p1Id]?.nickname ?? '?',
                'p2': m.isBye ? null : (players[m.p2Id]?.nickname ?? '?'),
                'result': m.isBye
                    ? 'bye'
                    : (m.accepted == null
                          ? '—'
                          : '${m.accepted!.p1Wins}-${m.accepted!.p2Wins}'),
              },
          ],
        },
    ],
  };

  /// Champion nickname of a (finished) tournament — top of final standings.
  String? championOf(TournamentEngine e) {
    if (e.rounds.isEmpty) return null;
    final s = e.currentStandings();
    return s.isEmpty ? null : players[s.first.playerId]?.nickname;
  }

  /// Count of current-round matches awaiting host adjudication — a score
  /// mismatch or a reported infraction. 0 unless a round is running.
  int get pendingReviewCount {
    final e = engine;
    if (e == null || e.status != TournamentStatus.running || e.rounds.isEmpty) {
      return 0;
    }
    return e.currentRound.matches
        .where((m) => m.state == MatchState.needsReview)
        .length;
  }

  /// JSON snapshot tailored to the viewer identified by [token] (may be null
  /// for an unauthenticated client that only sees public lobby info).
  String snapshotJsonFor(String? token) =>
      jsonEncode(snapshotFor(playerIdForToken(token)));

  Map<String, dynamic> snapshotFor(String? viewerId) {
    final e = engine;
    if (e == null) {
      return {'phase': 'idle', 'joinCode': null};
    }
    final isHost = viewerId != null && viewerId == hostPlayerId;
    final entry = e.entries.where((x) => x.playerId == viewerId).firstOrNull;

    return {
      'phase': e.status.name, // lobby | running | finished
      'name': e.name,
      'joinCode': joinCode,
      'round': e.rounds.length,
      'plannedRounds': e.plannedRounds,
      'kind': e.kind.name,
      'roundMinutes': e.roundMinutes,
      // Absolute deadline, not a remaining duration, so a client that misses a
      // push still counts down to the right moment.
      'roundEndsAt': e.roundEndsAt?.toIso8601String(),
      'isHost': isHost,
      'you': viewerId == null
          ? null
          : {
              'playerId': viewerId,
              'nickname': players[viewerId]?.nickname,
              'seated': entry != null,
              'dropped': entry?.dropped ?? false,
              'deckName': entry == null ? null : decks[entry.deckId]?.name,
              'decks': decksOf(
                viewerId,
              ).map((d) => {'id': d.id, 'name': d.name}).toList(),
            },
      'players': _playersArray(e),
      'standings': _standingsArray(e),
      'yourMatch': viewerId == null ? null : _matchView(e, viewerId),
      // host-only: every match in the current round + anything needing review
      'pairings': isHost && e.status == TournamentStatus.running
          ? [
              for (final m in e.currentRound.matches)
                {
                  'matchId': m.id,
                  'p1': players[m.p1Id]?.nickname ?? '?',
                  'p2': m.isBye ? null : (players[m.p2Id]?.nickname ?? '?'),
                  // Host-only view, so seat ids are safe here — the organizer
                  // needs them to re-pair before the round is played.
                  'p1Id': m.p1Id,
                  'p2Id': m.p2Id,
                  'editable':
                      m.isBye || (m.accepted == null && m.submissions.isEmpty),
                  'state': m.state.name,
                  'result': m.accepted == null
                      ? null
                      : '${m.accepted!.p1Wins}-${m.accepted!.p2Wins}',
                  'needsReview': m.state == MatchState.needsReview,
                  'reviewReason': m.reviewReason.name,
                  'isInfraction':
                      m.reviewReason == ReviewReason.infractionReported,
                  // Who flagged it (an infraction is recorded as infraction[pid]==false).
                  'reportedBy': [
                    for (final pid in [m.p1Id, if (!m.isBye) m.p2Id!])
                      if (m.infraction[pid] == false)
                        players[pid]?.nickname ?? '?',
                  ],
                  // What each player actually declared (canonical p1-p2 orientation),
                  // so the host resolves a mismatch to a result a player reported —
                  // not a hardcoded guess.
                  'reports': [
                    for (final pid in [m.p1Id, if (!m.isBye) m.p2Id!])
                      if (m.submissions[pid] != null)
                        {
                          'by': players[pid]?.nickname ?? '?',
                          'p1': m.submissions[pid]!.p1Wins,
                          'p2': m.submissions[pid]!.p2Wins,
                        },
                  ],
                },
            ]
          : [],
      // Number of matches needing the host's attention (mismatch or infraction).
      'attentionCount': isHost ? pendingReviewCount : 0,
      'roundComplete':
          e.status == TournamentStatus.running && e.isCurrentRoundComplete,
    };
  }

  /// The viewer's own current-round match, with reveal/infraction context.
  Map<String, dynamic>? _matchView(TournamentEngine e, String viewerId) {
    if (e.status != TournamentStatus.running) return null;
    final m = e.currentRound.matchFor(viewerId);
    if (m == null) return null;
    if (m.isBye) {
      return {'matchId': m.id, 'bye': true, 'state': m.state.name};
    }
    final isP1 = m.p1Id == viewerId;
    final oppId = m.opponentOf(viewerId)!;
    final revealed = m.accepted != null;
    final mySub = m.submissions[viewerId];
    return {
      'matchId': m.id,
      'bye': false,
      'opponent': players[oppId]?.nickname ?? '?',
      'state': m.state.name,
      'reviewReason': m.reviewReason.name,
      'mySubmission': mySub == null
          ? null
          : (isP1
                ? '${mySub.p1Wins}-${mySub.p2Wins}'
                : '${mySub.p2Wins}-${mySub.p1Wins}'),
      'accepted': m.accepted == null
          ? null
          : (isP1
                ? '${m.accepted!.p1Wins}-${m.accepted!.p2Wins}'
                : '${m.accepted!.p2Wins}-${m.accepted!.p1Wins}'),
      'needsResult': m.accepted == null && m.state != MatchState.needsReview,
      'revealed': revealed,
      'opponentDeck': revealed ? _deckView(e, oppId) : null,
      'yourInfraction': m.infraction[viewerId],
      'needsInfraction':
          revealed &&
          m.infraction[viewerId] == null &&
          m.state != MatchState.confirmed,
      'confirmed': m.state == MatchState.confirmed,
      // Optional questionnaire. Only ever the viewer's own answers plus whether
      // the opponent responded — never the opponent's answers.
      'survey': surveys[surveyKey(e.id, m.id)]?.viewFor(viewerId, clock()),
    };
  }

  Map<String, dynamic>? _deckView(TournamentEngine e, String playerId) {
    final entry = e.entries.where((x) => x.playerId == playerId).firstOrNull;
    if (entry == null) return null;
    final d = decks[entry.deckId];
    // Reveal the list as *registered for this event*, not whatever the deck has
    // been edited into since. Falls back to the live deck for pre-revision data.
    final r = revisionOf(entry);
    if (r == null && d == null) return null;
    final mainCards = r?.mainCards ?? d!.mainCards;
    final sideCards = r?.sideCards ?? d!.sideCards;
    return {
      'deckId': entry.deckId,
      'name': r?.name ?? d!.name,
      'mainboard': r?.mainboardText ?? d!.mainboardText,
      'sideboard': r?.sideboardText ?? d!.sideboardText,
      // Structured card-format data (with cached-image paths) when resolved.
      'cards': (mainCards.isNotEmpty || sideCards.isNotEmpty)
          ? [
              for (final c in mainCards) _cardJson(c, 'main'),
              for (final c in sideCards) _cardJson(c, 'side'),
            ]
          : null,
    };
  }

  Map<String, dynamic> _cardJson(DeckCardEntry e, String board) {
    final info = cardCatalog[e.cardId];
    return {
      'id': e.cardId,
      'qty': e.qty,
      'name': info?.name ?? '?',
      'type': info?.typeLine ?? '',
      'category': (info?.category ?? CardCategory.other).name,
      'board': board,
      'img': '/cards/img/${e.cardId}',
      'remoteImg': info?.imageUrl ?? '',
    };
  }

  String _deckNameFor(TournamentEngine e, String playerId) {
    final entry = e.entries.where((x) => x.playerId == playerId).firstOrNull;
    return entry == null ? '?' : (decks[entry.deckId]?.name ?? '?');
  }

  /// The roster of [e] with each entrant's named deck, drop flag, and record.
  List<Map<String, dynamic>> _playersArray(TournamentEngine e) => [
    for (final x in e.entries)
      {
        'nickname': players[x.playerId]?.nickname ?? '?',
        'deckName': decks[x.deckId]?.name ?? '?',
        'dropped': x.dropped,
        'disqualified': x.disqualified,
        'record': _recordString(e, x.playerId),
      },
  ];

  /// Ranked standings of [e] (empty before round 1), shared by the live
  /// snapshot and the history detail view.
  List<Map<String, dynamic>> _standingsArray(TournamentEngine e) {
    final standings = e.status == TournamentStatus.lobby
        ? <StandingRow>[]
        : e.currentStandings();
    return [
      for (var i = 0; i < standings.length; i++)
        {
          'rank': i + 1,
          'nickname': players[standings[i].playerId]?.nickname ?? '?',
          'deckName': _deckNameFor(e, standings[i].playerId),
          'matchPoints': standings[i].matchPoints,
          // The full MTR Appendix C tiebreaker chain, in the order it is
          // applied, so every screen can show why one player is above another.
          'omw': (standings[i].omw * 100).toStringAsFixed(1),
          'gw': (standings[i].gw * 100).toStringAsFixed(1),
          'ogw': (standings[i].ogw * 100).toStringAsFixed(1),
          'record': _recordString(e, standings[i].playerId),
          'disqualified':
              e.entryOf(standings[i].playerId)?.disqualified ?? false,
        },
    ];
  }

  String _recordString(TournamentEngine e, String playerId) {
    var w = 0, l = 0, d = 0;
    for (final r in e.rounds) {
      for (final m in r.matches) {
        if (m.accepted == null && !m.isBye) continue;
        if (m.isBye && m.p1Id == playerId) {
          w++;
          continue;
        }
        if (!m.involves(playerId)) continue;
        final s = m.accepted!;
        final isP1 = m.p1Id == playerId;
        final myWins = isP1 ? s.p1Wins : s.p2Wins;
        final oppWins = isP1 ? s.p2Wins : s.p1Wins;
        if (s.isDoubleLoss || myWins < oppWins) {
          l++;
        } else if (myWins > oppWins) {
          w++;
        } else {
          d++;
        }
      }
    }
    return '$w-$l-$d';
  }

  TournamentEngine _requireEngine() {
    final e = engine;
    if (e == null) throw EngineError('No active tournament.');
    return e;
  }

  Match _findMatch(TournamentEngine e, String matchId) {
    for (final r in e.rounds) {
      for (final m in r.matches) {
        if (m.id == matchId) return m;
      }
    }
    throw EngineError('No such match: $matchId');
  }
}
