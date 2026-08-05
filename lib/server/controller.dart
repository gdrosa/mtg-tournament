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
import '../shared/models.dart';
import '../shared/stats.dart';
import '../shared/tournament_engine.dart';
import 'persistence.dart';

const _uuid = Uuid();

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

  // ---- live connections ----
  final Set<Connection> _connections = {};

  final Random _rng;
  void Function()? onChange; // hook so the host UI can rebuild
  // Fired after any deck is saved (organizer OR a participant via /api/deck) with
  // the saved deck's id, so the Flutter host can resolve+cache its card images in
  // the background. Null in headless/test runs (pure Dart, no Scryfall).
  void Function(String deckId)? onDeckSaved;
  Persistence? store; // durable crash-resume storage (optional)

  ServerController({Random? rng}) : _rng = rng ?? Random();

  // ========================================================================
  // Identity / decks (durable)
  // ========================================================================

  /// Resolve a session: reuse the player bound to [token], else create a new
  /// durable player for [nickname]. Returns the (token, playerId).
  ({String token, String playerId}) resolveSession(
    String nickname,
    String? token,
  ) {
    if (token != null && _tokenToPlayer.containsKey(token)) {
      final pid = _tokenToPlayer[token]!;
      // allow a returning player to update their display nickname
      players[pid] = Player(id: pid, nickname: nickname.trim());
      return (token: token, playerId: pid);
    }
    final pid = _uuid.v4();
    final newToken = token ?? _uuid.v4();
    players[pid] = Player(id: pid, nickname: nickname.trim());
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
  }) {
    final id = deckId ?? _uuid.v4();
    _requireEditableDeck(id);
    final deck = Deck(
      id: id,
      ownerId: ownerId,
      name: name.trim(),
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
  }) {
    this.hostPlayerId = hostPlayerId;
    engine = TournamentEngine(
      id: _uuid.v4(),
      name: name,
      createdAt: DateTime.now(),
      rng: _rng,
    );
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
    e.addEntry(playerId, deckId);
    _changed();
  }

  void startTournament() {
    _requireEngine().start();
    _changed();
  }

  void advanceRound() {
    _requireEngine().advanceRound();
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
    'players': players.values.map((p) => p.toJson()).toList(),
    'decks': decks.values.map((d) => d.toJson()).toList(),
    'cards': cardCatalog.values.map((c) => c.toJson()).toList(),
    'tokens': _tokenToPlayer,
    'ownerPlayerId': ownerPlayerId,
    'ownerToken': ownerToken,
    'hostPlayerId': hostPlayerId,
    'joinCode': joinCode,
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
    for (final p in (j['players'] as List)) {
      final pl = Player.fromJson(p as Map);
      nextPlayers[pl.id] = pl;
    }
    for (final d in (j['decks'] as List)) {
      final dk = Deck.fromJson(d as Map);
      nextDecks[dk.id] = dk;
    }
    for (final c in (j['cards'] as List? ?? const [])) {
      final ci = CardInfo.fromJson(c as Map);
      nextCards[ci.id] = ci;
    }
    (j['tokens'] as Map).forEach(
      (k, v) => nextTokens[k as String] = v as String,
    );
    final nextOwnerPlayerId = j['ownerPlayerId'] as String?;
    final nextOwnerToken = j['ownerToken'] as String?;
    final nextHostPlayerId = j['hostPlayerId'] as String?;
    final nextJoinCode = j['joinCode'] as String?;
    final nextEngine = j['engine'] == null
        ? null
        : TournamentEngine.fromJson(j['engine'] as Map, rng: _rng);
    for (final a in (j['archive'] as List? ?? const [])) {
      nextArchive.add(TournamentEngine.fromJson(a as Map, rng: _rng));
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
    ownerPlayerId = nextOwnerPlayerId;
    ownerToken = nextOwnerToken;
    hostPlayerId = nextHostPlayerId;
    joinCode = nextJoinCode;
    engine = nextEngine;
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

  /// A full read-only view of one tournament for the history detail screen:
  /// final standings, the roster with decklists, and every round's results.
  Map<String, dynamic> historyDetail(TournamentEngine e) => {
    'id': e.id,
    'name': e.name,
    'date': e.createdAt.toIso8601String(),
    'status': e.status.name,
    'roundCount': e.rounds.length,
    'playerCount': e.entries.length,
    'standings': _standingsArray(e),
    'players': [
      for (final x in e.entries)
        {
          'playerId': x.playerId,
          'nickname': players[x.playerId]?.nickname ?? '?',
          'deckName': decks[x.deckId]?.name ?? '?',
          'dropped': x.dropped,
          'record': _recordString(e, x.playerId),
          'main': decks[x.deckId]?.mainboardText ?? '',
          'side': decks[x.deckId]?.sideboardText ?? '',
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
    };
  }

  Map<String, dynamic>? _deckView(TournamentEngine e, String playerId) {
    final entry = e.entries.where((x) => x.playerId == playerId).firstOrNull;
    if (entry == null) return null;
    final d = decks[entry.deckId];
    if (d == null) return null;
    return {
      'deckId': d.id,
      'name': d.name,
      'mainboard': d.mainboardText,
      'sideboard': d.sideboardText,
      // Structured card-format data (with cached-image paths) when resolved.
      'cards': d.hasCards
          ? [
              for (final c in d.mainCards) _cardJson(c, 'main'),
              for (final c in d.sideCards) _cardJson(c, 'side'),
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
          'omw': (standings[i].omw * 100).toStringAsFixed(1),
          'gw': (standings[i].gw * 100).toStringAsFixed(1),
          'record': _recordString(e, standings[i].playerId),
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
        if (myWins > oppWins) {
          w++;
        } else if (myWins < oppWins) {
          l++;
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
