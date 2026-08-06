/// Authoritative, in-memory tournament state machine.
///
/// Pure logic (no I/O, no sockets, no DB, no implicit clock/RNG — both are
/// injected) so it is fully deterministic and unit-testable on Windows with no
/// device. The server isolate owns one instance; persistence and broadcast wrap
/// it (persist-then-push). See ARCHITECTURE.md §4.
library;

import 'dart:math';

import 'models.dart';
import 'swiss.dart';

/// Thrown when a command is illegal for the current state.
class EngineError implements Exception {
  final String message;
  EngineError(this.message);
  @override
  String toString() => 'EngineError: $message';
}

/// Upper bound on a hand-set Swiss round count — a guard against a fat-fingered
/// "50", not a competitive rule.
const int kMaxPlannedRounds = 20;

/// Longest configurable round timer.
const int kMaxRoundMinutes = 240;

class TournamentEngine {
  final String id;
  final String name;
  final DateTime createdAt;
  final Random _rng;
  final DateTime Function() _clock;

  /// Swiss or single elimination. Fixed at creation: changing it mid-event
  /// would invalidate every pairing already played.
  final TournamentKind kind;

  /// Free-text format ("Modern", "Standard", "Cube"). Empty when unspecified —
  /// statistics simply group those together under "Unspecified".
  final String format;

  /// Free-text league/series name. Tournaments sharing one are a series; there
  /// is deliberately no separate Series entity to create and keep in sync.
  final String series;

  TournamentStatus status = TournamentStatus.lobby;
  final List<Entry> entries = [];
  final List<Round> rounds = [];

  /// How many rounds this event will play. 0 means "not decided yet" — [start]
  /// then fills in the default for [kind] and the field size. Set by hand with
  /// [setPlannedRounds].
  int plannedRounds = 0;

  /// Round length in minutes, or 0 for no timer. Optional and advisory: see
  /// [Round.endsAt].
  int roundMinutes = 0;

  TournamentEngine({
    required this.id,
    required this.name,
    required this.createdAt,
    this.kind = TournamentKind.swiss,
    this.format = '',
    this.series = '',
    this.roundMinutes = 0,
    Random? rng,
    DateTime Function()? clock,
  }) : _rng = rng ?? Random(),
       _clock = clock ?? DateTime.now;

  // ---- Lobby -------------------------------------------------------------

  void addEntry(String playerId, String deckId) {
    if (status != TournamentStatus.lobby) {
      throw EngineError('Cannot join after the tournament has started.');
    }
    if (entries.any((e) => e.playerId == playerId)) {
      throw EngineError('Player $playerId is already entered.');
    }
    entries.add(Entry(playerId: playerId, deckId: deckId));
  }

  List<String> get activePlayerIds => [
    for (final e in entries)
      if (!e.dropped) e.playerId,
  ];

  /// The round count this event would play if nobody overrode it.
  int get defaultRounds => switch (kind) {
    TournamentKind.swiss => recommendedRounds(activePlayerIds.length),
    TournamentKind.singleElimination => bracketRounds(activePlayerIds.length),
  };

  /// Override the planned Swiss round count — before the event or during it,
  /// but never below the rounds already played (they happened) and never above
  /// [kMaxPlannedRounds]. A bracket's length is arithmetic, not a preference,
  /// so single elimination refuses.
  void setPlannedRounds(int n) {
    if (kind == TournamentKind.singleElimination) {
      throw EngineError('A knockout bracket sets its own number of rounds.');
    }
    final floor = rounds.isEmpty ? 1 : rounds.length;
    if (n < floor || n > kMaxPlannedRounds) {
      throw EngineError(
        'Rounds must be between $floor and $kMaxPlannedRounds.',
      );
    }
    plannedRounds = n;
  }

  /// Lock the roster and generate round 1.
  void start() {
    if (status != TournamentStatus.lobby) {
      throw EngineError('Tournament already started.');
    }
    if (activePlayerIds.length < 2) {
      throw EngineError('Need at least 2 players to start.');
    }
    status = TournamentStatus.running;
    // A knockout's length follows from the field, so a stale lobby override
    // (players joined after it was set) must not truncate the bracket.
    if (plannedRounds == 0 || kind == TournamentKind.singleElimination) {
      plannedRounds = defaultRounds;
    }
    final order = List<String>.of(activePlayerIds)..shuffle(_rng);
    _appendRoundFrom(
      pairRound(orderedPlayers: order, playedKeys: {}, hadBye: {}),
    );
  }

  Round get currentRound {
    if (rounds.isEmpty) throw EngineError('No round in progress.');
    return rounds.last;
  }

  // ---- Result reconciliation --------------------------------------------

  Match _match(String matchId) {
    for (final r in rounds) {
      for (final m in r.matches) {
        if (m.id == matchId) return m;
      }
    }
    throw EngineError('No such match: $matchId');
  }

  /// Reject scores that aren't a legal best-of-3 line, so a hostile/buggy client
  /// can't poison the GW%/OGW% tiebreakers (e.g. a negative or 9-0 submission).
  ///
  /// [allowDoubleLoss] opens up 0-0, which only [disqualify] may produce.
  static void _validateScore(GameScore s, {bool allowDoubleLoss = false}) {
    final total = s.p1Wins + s.p2Wins + s.draws;
    if (allowDoubleLoss && s.isDoubleLoss) return;
    if (s.p1Wins < 0 ||
        s.p2Wins < 0 ||
        s.draws < 0 ||
        s.p1Wins > 2 ||
        s.p2Wins > 2 ||
        total < 1 ||
        total > 3) {
      throw EngineError('Not a valid best-of-3 score.');
    }
  }

  /// A player submits the Bo3 result, in canonical (p1, p2) orientation.
  /// Accepted only when both distinct players submit matching scores.
  void submitResult(String matchId, String byPlayerId, GameScore score) {
    _validateScore(score);
    final m = _match(matchId);
    if (m.isBye) throw EngineError('Cannot submit a result for a bye.');
    if (!m.involves(byPlayerId)) {
      throw EngineError('$byPlayerId is not in match $matchId.');
    }
    if (m.accepted != null) {
      // Locked once a result is accepted; idempotent re-send is a no-op.
      if (m.submissions[byPlayerId] == score) return;
      throw EngineError('Result already accepted; ask the host to amend.');
    }

    m.submissions[byPlayerId] = score;

    // Need both distinct players' submissions to reconcile.
    final s1 = m.submissions[m.p1Id];
    final s2 = m.submissions[m.p2Id];
    if (s1 == null || s2 == null) {
      m.state = MatchState.awaitingSecond;
      m.reviewReason = ReviewReason.none;
      return;
    }
    if (s1 == s2) {
      m.accepted = s1;
      m.state = MatchState.resultAccepted;
      m.reviewReason = ReviewReason.none;
      _settleIfFullyConfirmed(m);
    } else {
      m.accepted = null;
      m.state = MatchState.needsReview;
      m.reviewReason = ReviewReason.resultMismatch;
      m.disputed = true;
    }
  }

  /// After the result is accepted and decklists revealed, each player confirms
  /// "no infractions" (true) or reports one (false).
  void confirmNoInfraction(String matchId, String byPlayerId, bool ok) {
    final m = _match(matchId);
    if (m.isBye) return;
    if (!m.involves(byPlayerId)) {
      throw EngineError('$byPlayerId is not in match $matchId.');
    }
    // A confirmed match is terminal: a late/duplicate thumbs-up (stale snapshot,
    // retry, double-tap, or one arriving after a drop/host-resolve already
    // confirmed it) is a no-op. Without this it would downgrade to resultAccepted
    // and deadlock the round (the absent side never re-confirms).
    if (m.state == MatchState.confirmed) return;
    if (m.accepted == null) {
      throw EngineError('Confirm infractions only after a result is accepted.');
    }
    m.infraction[byPlayerId] = ok;
    if (!ok) {
      m.state = MatchState.needsReview;
      m.reviewReason = ReviewReason.infractionReported;
      m.disputed = true;
      return;
    }
    _settleIfFullyConfirmed(m);
  }

  void _settleIfFullyConfirmed(Match m) {
    if (m.accepted == null) return;
    if (m.state == MatchState.confirmed) {
      return; // never downgrade a terminal match
    }
    final bothOk = m.infraction[m.p1Id] == true && m.infraction[m.p2Id] == true;
    if (bothOk && m.reviewReason != ReviewReason.resultMismatch) {
      m.state = MatchState.confirmed;
      m.reviewReason = ReviewReason.none;
    } else if (m.state != MatchState.needsReview) {
      m.state = MatchState.resultAccepted;
    }
  }

  /// Host adjudication of a flagged/disputed match: set the authoritative
  /// result, optionally with a note, and confirm it.
  void hostResolve(String matchId, GameScore result, {String? note}) {
    _validateScore(result);
    final m = _match(matchId);
    if (m.isBye) throw EngineError('A bye needs no resolution.');
    // Record *why* the host stepped in before clearing the reason: statistics
    // separate "the players disagreed" from "the host corrected a typo".
    if (m.state == MatchState.needsReview) m.disputed = true;
    m.accepted = result;
    m.hostNote = note;
    m.adjudicated = true;
    m.state = MatchState.confirmed;
    m.reviewReason = ReviewReason.none;
  }

  /// Disqualify one or both players in [matchId] — the third way out of a
  /// decklist review, alongside amending the result and letting it stand.
  ///
  /// A disqualified player is out of the event: dropped, flagged in their
  /// entry so history never mistakes it for going home early, and given the
  /// loss. Disqualifying both is a double loss (0-0), not a draw.
  void disqualify(String matchId, List<String> playerIds, {String? note}) {
    final m = _match(matchId);
    if (m.isBye) throw EngineError('There is nobody to disqualify in a bye.');
    if (playerIds.isEmpty) throw EngineError('Nobody was selected.');
    for (final pid in playerIds) {
      if (!m.involves(pid)) throw EngineError('$pid is not in match $matchId.');
    }
    final out = playerIds.toSet();
    for (final pid in out) {
      final e = entryOf(pid);
      if (e == null) throw EngineError('No such entry: $pid');
      e.disqualified = true;
      e.dropped = true;
    }
    final bothOut = out.contains(m.p1Id) && out.contains(m.p2Id);
    final result = bothOut
        ? const GameScore(0, 0)
        : (out.contains(m.p1Id)
              ? const GameScore(0, 2)
              : const GameScore(2, 0));
    _validateScore(result, allowDoubleLoss: true);
    m.accepted = result;
    m.hostNote = note;
    m.adjudicated = true;
    m.disputed = true;
    m.state = MatchState.confirmed;
    m.reviewReason = ReviewReason.none;
  }

  // ---- Drops & rounds ----------------------------------------------------

  /// Drop a player. A drop mid-round awards their current opponent the match
  /// (2-0) if that match is not yet resolved.
  void dropPlayer(String playerId) {
    final e = entries.firstWhere(
      (e) => e.playerId == playerId,
      orElse: () => throw EngineError('No such entry: $playerId'),
    );
    e.dropped = true;
    if (rounds.isEmpty) return;
    final m = currentRound.matchFor(playerId);
    if (m == null || m.isBye || m.state == MatchState.confirmed) return;
    // Preserve an already-agreed game score (resultAccepted / infraction review);
    // only synthesize a 2-0 award when no result was accepted yet. Either way
    // confirm the match, since the dropped player won't send infraction thumbs.
    if (m.accepted == null) {
      final opp = m.opponentOf(playerId)!;
      m.accepted = (opp == m.p1Id)
          ? const GameScore(2, 0)
          : const GameScore(0, 2);
    }
    m.state = MatchState.confirmed;
    m.reviewReason = ReviewReason.none;
  }

  bool get isCurrentRoundComplete =>
      rounds.isNotEmpty && currentRound.isComplete;

  /// Generate the next round once the current one is fully confirmed.
  void advanceRound() {
    if (status != TournamentStatus.running) {
      throw EngineError('Tournament is not running.');
    }
    if (!isCurrentRoundComplete) {
      throw EngineError('Round ${currentRound.number} is not fully confirmed.');
    }
    if (rounds.length >= plannedRounds) {
      status = TournamentStatus.finished;
      return;
    }
    final ordered = kind == TournamentKind.singleElimination
        ? _survivors()
        : _standingsOrder();
    // A knockout runs out of players before it runs out of rounds whenever the
    // bracket had byes; either way, one player left is the end.
    if (ordered.length < 2) {
      status = TournamentStatus.finished;
      return;
    }
    _appendRoundFrom(
      pairRound(
        orderedPlayers: ordered,
        playedKeys: _playedKeys(),
        hadBye: _byePlayers(),
      ),
    );
  }

  /// Active players in standings order — the Swiss pairing order.
  List<String> _standingsOrder() {
    final active = activePlayerIds.toSet();
    return [
      for (final row in currentStandings())
        if (active.contains(row.playerId)) row.playerId,
    ];
  }

  /// Winners of the current round, in bracket order. Everyone else is out; they
  /// keep the record they earned and simply stop being paired.
  List<String> _survivors() {
    final active = activePlayerIds.toSet();
    final out = <String>[];
    for (final m in currentRound.matches) {
      if (m.isBye) {
        if (active.contains(m.p1Id)) out.add(m.p1Id);
        continue;
      }
      final s = m.accepted!;
      if (s.isDoubleLoss) continue; // both disqualified: nobody advances
      if (s.isDraw) {
        // Nothing in a knockout can break this tie, so it is the organizer's
        // call — and refusing is far better than picking a player silently.
        throw EngineError(
          'A knockout needs a winner in every match. Set a result for the '
          'drawn match before generating the next round.',
        );
      }
      final winner = s.p1IsWinner ? m.p1Id : m.p2Id!;
      if (active.contains(winner)) out.add(winner);
    }
    return out;
  }

  // ---- Manual pairing edits -----------------------------------------------

  /// Swap where two players are seated in the current round, before either
  /// match has a result. Moving one player is the same operation as swapping
  /// them with whoever they are displacing, so this one command covers every
  /// edit an organizer actually makes (including moving the bye).
  void swapPairing(String playerA, String playerB) {
    if (rounds.isEmpty) throw EngineError('No round to edit.');
    if (playerA == playerB) throw EngineError('Pick two different players.');
    final r = currentRound;
    final ma = r.matchFor(playerA);
    final mb = r.matchFor(playerB);
    if (ma == null || mb == null) {
      throw EngineError('Both players must be in the current round.');
    }
    if (identical(ma, mb)) {
      throw EngineError('Those two are already paired against each other.');
    }
    for (final m in [ma, mb]) {
      // A bye carries an auto-awarded 2-0 that is re-created below; a real
      // match with a result is history and must not be re-seated.
      if (!m.isBye && (m.accepted != null || m.submissions.isNotEmpty)) {
        throw EngineError('That match already has a reported result.');
      }
    }
    r.matches[r.matches.indexOf(ma)] = _reseat(ma, playerA, playerB);
    r.matches[r.matches.indexOf(mb)] = _reseat(mb, playerB, playerA);
  }

  /// A copy of [m] with [out] replaced by [incoming], back at the start of its
  /// lifecycle (a bye keeps its automatic win).
  Match _reseat(Match m, String out, String incoming) {
    final fresh = Match(
      id: m.id,
      p1Id: m.p1Id == out ? incoming : m.p1Id,
      p2Id: m.p2Id == out ? incoming : m.p2Id,
    );
    if (fresh.isBye) {
      fresh.accepted = const GameScore(2, 0);
      fresh.state = MatchState.confirmed;
    }
    return fresh;
  }

  // ---- Round timer --------------------------------------------------------

  /// Set the round length in minutes (0 turns the timer off). Applies to the
  /// current round immediately and to every round generated afterwards.
  void setRoundMinutes(int minutes) {
    if (minutes < 0 || minutes > kMaxRoundMinutes) {
      throw EngineError('A round can be 0 to $kMaxRoundMinutes minutes long.');
    }
    roundMinutes = minutes;
    if (rounds.isEmpty) return;
    if (minutes == 0) {
      currentRound.endsAt = null;
    } else {
      startRoundTimer();
    }
  }

  /// Start (or restart) the current round's clock from now.
  void startRoundTimer() {
    if (rounds.isEmpty) throw EngineError('No round in progress.');
    if (roundMinutes <= 0) throw EngineError('Set a round length first.');
    currentRound.endsAt = _clock().add(Duration(minutes: roundMinutes));
  }

  /// Stop the current round's clock without changing the configured length.
  void stopRoundTimer() {
    if (rounds.isNotEmpty) currentRound.endsAt = null;
  }

  /// When the current round is due to end, or null when no timer is running.
  DateTime? get roundEndsAt => rounds.isEmpty ? null : currentRound.endsAt;

  void finish() => status = TournamentStatus.finished;

  // ---- Standings ---------------------------------------------------------

  List<StandingRow> currentStandings() =>
      computeStandings(_recordsSoFar(), activePlayerIds);

  /// All entered player ids (including dropped) — the population a finished
  /// tournament's history is computed over.
  List<String> get allPlayerIds => [for (final e in entries) e.playerId];

  /// Flattened confirmed match records (byes counted as 2-0). This is the input
  /// the standings/stats engines consume and the basis for cross-tournament
  /// history (see [TournamentHistoryEntry]).
  List<MatchRecord> get matchRecords => _recordsSoFar().toList();

  /// Every match with a known result, tagged with its round number. This is the
  /// input the statistics layer denormalizes into facts; unresolved matches are
  /// skipped so an in-progress event contributes only what is settled.
  Iterable<({int round, Match match})> get playedMatches sync* {
    for (final r in rounds) {
      for (final m in r.matches) {
        if (m.accepted == null && !m.isBye) continue;
        yield (round: r.number, match: m);
      }
    }
  }

  /// The [Entry] for [playerId], or null if they never entered.
  Entry? entryOf(String playerId) =>
      entries.where((e) => e.playerId == playerId).firstOrNull;

  // ---- Internals ---------------------------------------------------------

  void _appendRoundFrom(Pairing p) {
    final n = rounds.length + 1;
    final matches = <Match>[];
    var i = 0;
    for (final pair in p.pairs) {
      matches.add(Match(id: 'r${n}m${i++}', p1Id: pair[0], p2Id: pair[1]));
    }
    if (p.bye != null) {
      matches.add(
        Match(id: 'r${n}m${i++}', p1Id: p.bye!, state: MatchState.confirmed)
          ..accepted = const GameScore(2, 0),
      );
    }
    rounds.add(
      Round(
        n,
        matches,
        endsAt: roundMinutes > 0
            ? _clock().add(Duration(minutes: roundMinutes))
            : null,
      ),
    );
  }

  Iterable<MatchRecord> _recordsSoFar() sync* {
    for (final r in rounds) {
      for (final m in r.matches) {
        if (m.accepted == null && !m.isBye) continue;
        yield MatchRecord(m.p1Id, m.p2Id, m.accepted ?? const GameScore(2, 0));
      }
    }
  }

  Set<String> _playedKeys() {
    final keys = <String>{};
    for (final r in rounds) {
      for (final m in r.matches) {
        if (!m.isBye) keys.add(pairKey(m.p1Id, m.p2Id!));
      }
    }
    return keys;
  }

  Set<String> _byePlayers() {
    final byes = <String>{};
    for (final r in rounds) {
      for (final m in r.matches) {
        if (m.isBye) byes.add(m.p1Id);
      }
    }
    return byes;
  }

  // ---- serialization (crash-resume) -------------------------------------

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    if (kind != TournamentKind.swiss) 'kind': kind.name,
    if (format.isNotEmpty) 'format': format,
    if (series.isNotEmpty) 'series': series,
    if (roundMinutes > 0) 'roundMinutes': roundMinutes,
    'status': status.name,
    'plannedRounds': plannedRounds,
    'entries': entries.map((e) => e.toJson()).toList(),
    'rounds': rounds.map((r) => r.toJson()).toList(),
  };

  factory TournamentEngine.fromJson(
    Map j, {
    Random? rng,
    DateTime Function()? clock,
  }) {
    final e = TournamentEngine(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      // Saves written before knockouts existed are all Swiss.
      kind: TournamentKind.values.byName((j['kind'] as String?) ?? 'swiss'),
      format: (j['format'] as String?) ?? '',
      series: (j['series'] as String?) ?? '',
      roundMinutes: (j['roundMinutes'] as num?)?.toInt() ?? 0,
      rng: rng,
      clock: clock,
    );
    e.status = TournamentStatus.values.byName(j['status'] as String);
    e.plannedRounds = j['plannedRounds'] as int;
    e.entries.addAll([
      for (final x in (j['entries'] as List)) Entry.fromJson(x as Map),
    ]);
    e.rounds.addAll([
      for (final r in (j['rounds'] as List)) Round.fromJson(r as Map),
    ]);
    return e;
  }
}
