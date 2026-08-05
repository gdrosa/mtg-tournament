/// Pure Swiss pairing + tiebreaker engine.
///
/// Authority: WPN Magic Tournament Rules, Appendix C (Tiebreakers) and
/// Appendix E (Recommended Rounds). See ARCHITECTURE.md §7.
///
/// Everything here is a pure function of its inputs — no I/O, no clock, no
/// global RNG — so it is fully deterministic and unit-testable on any platform.
library;

import 'models.dart';

/// The 0.33 floor applied to each match-win% / game-win% component (MTR App. C).
const double kTiebreakFloor = 1.0 / 3.0;

/// Match points awarded.
const int kWinPoints = 3;
const int kDrawPoints = 1;
const int kLossPoints = 0;

/// Recommended number of Swiss rounds for [players] (MTR Appendix E, "other
/// formats" / Constructed column). Returns 0 for fewer than 2 players.
int recommendedRounds(int players) {
  if (players < 2) return 0;
  if (players <= 8) return 3;
  if (players <= 16) return 5;
  if (players <= 32) return 5;
  if (players <= 64) return 6;
  if (players <= 128) return 7;
  if (players <= 226) return 8;
  if (players <= 409) return 9;
  return 10;
}

/// Canonical unordered key for a pair of player ids.
String pairKey(String a, String b) => a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

class _Agg {
  int matchPoints = 0;
  int rounds = 0;
  int gamePoints = 0;
  int games = 0;
  int byes = 0;
  final List<String> opponents = [];
}

/// Compute full standings from the flattened [records], for [players].
///
/// Records should include every match with a known result (byes included).
/// Result is sorted by the MTR order: match points, then OMW%, GW%, OGW%,
/// with player id as a final stable tiebreak.
List<StandingRow> computeStandings(
  Iterable<MatchRecord> records,
  Iterable<String> players,
) {
  final agg = {for (final p in players) p: _Agg()};
  _Agg of(String id) => agg.putIfAbsent(id, () => _Agg());

  for (final r in records) {
    if (r.isBye) {
      final a = of(r.p1);
      a.matchPoints += kWinPoints;
      a.rounds += 1;
      a.gamePoints += 6; // treated as a 2-0 win
      a.games += 2;
      a.byes += 1;
      continue;
    }
    final p1 = of(r.p1);
    final p2 = of(r.p2!);
    final s = r.score;
    // match points
    if (s.p1IsWinner) {
      p1.matchPoints += kWinPoints;
      p2.matchPoints += kLossPoints;
    } else if (s.p2IsWinner) {
      p2.matchPoints += kWinPoints;
      p1.matchPoints += kLossPoints;
    } else {
      p1.matchPoints += kDrawPoints;
      p2.matchPoints += kDrawPoints;
    }
    p1.rounds += 1;
    p2.rounds += 1;
    final total = s.totalGames;
    p1.gamePoints += s.p1Wins * 3 + s.draws;
    p2.gamePoints += s.p2Wins * 3 + s.draws;
    p1.games += total;
    p2.games += total;
    p1.opponents.add(r.p2!);
    p2.opponents.add(r.p1);
  }

  // own floored match-win% and game-win% (used as opponents' components)
  double mwp(String id) {
    final a = of(id);
    if (a.rounds == 0) return kTiebreakFloor;
    final v = a.matchPoints / (3 * a.rounds);
    return v < kTiebreakFloor ? kTiebreakFloor : v;
  }

  double gwp(String id) {
    final a = of(id);
    if (a.games == 0) return kTiebreakFloor;
    final v = a.gamePoints / (3 * a.games);
    return v < kTiebreakFloor ? kTiebreakFloor : v;
  }

  double meanOf(List<String> ids, double Function(String) f) {
    if (ids.isEmpty) return 0.0;
    var sum = 0.0;
    for (final id in ids) {
      sum += f(id);
    }
    return sum / ids.length;
  }

  final rows = <StandingRow>[];
  for (final p in agg.keys) {
    final a = of(p);
    rows.add(
      StandingRow(
        playerId: p,
        matchPoints: a.matchPoints,
        roundsPlayed: a.rounds,
        omw: meanOf(a.opponents, mwp), // byes never added to opponents
        gw: gwp(p),
        ogw: meanOf(a.opponents, gwp),
        byes: a.byes,
      ),
    );
  }

  rows.sort((x, y) {
    int c = y.matchPoints.compareTo(x.matchPoints);
    if (c != 0) return c;
    c = y.omw.compareTo(x.omw);
    if (c != 0) return c;
    c = y.gw.compareTo(x.gw);
    if (c != 0) return c;
    c = y.ogw.compareTo(x.ogw);
    if (c != 0) return c;
    return x.playerId.compareTo(y.playerId); // stable
  });
  return rows;
}

/// Result of pairing one round.
class Pairing {
  final List<List<String>> pairs; // each [p1, p2]
  final String? bye; // player receiving the bye, if any
  final bool forcedRematch; // true if constraints had to be relaxed
  const Pairing(this.pairs, this.bye, {this.forcedRematch = false});
}

/// Pair one round.
///
/// [orderedPlayers] are the active (non-dropped) players already sorted in
/// pairing order (random for round 1; standings order afterwards). [playedKeys]
/// are [pairKey]s of already-played pairings; [hadBye] are players who already
/// had a bye. Top-of-order players are paired first, dropping down through
/// brackets as needed, avoiding rematches via backtracking.
Pairing pairRound({
  required List<String> orderedPlayers,
  required Set<String> playedKeys,
  required Set<String> hadBye,
}) {
  final players = List<String>.of(orderedPlayers);
  String? bye;
  if (players.length.isOdd) {
    // Bye to the lowest-standing eligible (never-byed) player; else the lowest.
    int idx = players.lastIndexWhere((p) => !hadBye.contains(p));
    if (idx < 0) idx = players.length - 1;
    bye = players.removeAt(idx);
  }

  List<List<String>>? attempt(bool avoidRematch) {
    List<List<String>>? match(List<String> rem) {
      if (rem.isEmpty) return [];
      final a = rem.first;
      for (var i = 1; i < rem.length; i++) {
        final b = rem[i];
        if (avoidRematch && playedKeys.contains(pairKey(a, b))) continue;
        final rest = [
          for (var j = 1; j < rem.length; j++)
            if (j != i) rem[j],
        ];
        final sub = match(rest);
        if (sub != null) {
          return [
            [a, b],
            ...sub,
          ];
        }
      }
      return null;
    }

    return match(players);
  }

  final clean = attempt(true);
  if (clean != null) return Pairing(clean, bye);
  // No constraint-satisfying matching exists — relax and allow a rematch.
  final relaxed = attempt(false)!;
  return Pairing(relaxed, bye, forcedRematch: true);
}
