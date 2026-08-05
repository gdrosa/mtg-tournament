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

class TournamentEngine {
  final String id;
  final String name;
  final DateTime createdAt;
  final Random _rng;

  TournamentStatus status = TournamentStatus.lobby;
  final List<Entry> entries = [];
  final List<Round> rounds = [];
  int plannedRounds = 0;

  TournamentEngine({
    required this.id,
    required this.name,
    required this.createdAt,
    Random? rng,
  }) : _rng = rng ?? Random();

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

  /// Lock the roster and generate round 1.
  void start() {
    if (status != TournamentStatus.lobby) {
      throw EngineError('Tournament already started.');
    }
    if (activePlayerIds.length < 2) {
      throw EngineError('Need at least 2 players to start.');
    }
    status = TournamentStatus.running;
    if (plannedRounds == 0) {
      plannedRounds = recommendedRounds(activePlayerIds.length);
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
  static void _validateScore(GameScore s) {
    final total = s.p1Wins + s.p2Wins + s.draws;
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
    m.accepted = result;
    m.hostNote = note;
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
    final standings = currentStandings();
    final active = activePlayerIds.toSet();
    final ordered = [
      for (final row in standings)
        if (active.contains(row.playerId)) row.playerId,
    ];
    _appendRoundFrom(
      pairRound(
        orderedPlayers: ordered,
        playedKeys: _playedKeys(),
        hadBye: _byePlayers(),
      ),
    );
  }

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
    rounds.add(Round(n, matches));
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
    'status': status.name,
    'plannedRounds': plannedRounds,
    'entries': entries.map((e) => e.toJson()).toList(),
    'rounds': rounds.map((r) => r.toJson()).toList(),
  };

  factory TournamentEngine.fromJson(Map j, {Random? rng}) {
    final e = TournamentEngine(
      id: j['id'] as String,
      name: j['name'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      rng: rng,
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
