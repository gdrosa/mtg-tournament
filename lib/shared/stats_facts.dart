/// The normalized fact table every statistic is computed from.
///
/// One settled match becomes one [MatchFact], denormalized with the deck
/// revision, archetype, format and series it was played under. Everything in
/// `stats_service.dart` is then a fold over a filtered list of facts — no
/// statistic reaches back into the live engine, and none is computed inside a
/// widget.
///
/// PURE DART (no I/O, no Flutter, no clock) so every number is deterministic
/// and unit-testable on Windows.
library;

import 'dart:math' as math;

import 'models.dart';
import 'stats.dart' show Outcome, Record;

export 'stats.dart' show Outcome, Record;

/// Below this many matches a rate is a hint, not a finding. Every report
/// carries its sample size so the UI can say so rather than imply certainty.
const int kReliableSample = 20;

/// One player's side of a match, with the identity that was actually played.
class SideFact {
  final String playerId;
  final String deckId;

  /// The immutable revision played. Empty for pre-revision history.
  final String revisionId;
  final String deckName;
  final String archetype;
  final bool dropped;

  const SideFact({
    required this.playerId,
    required this.deckId,
    this.revisionId = '',
    this.deckName = '',
    this.archetype = '',
    this.dropped = false,
  });

  /// Grouping label, never empty, so an unlabelled deck still aggregates.
  String get archetypeLabel {
    if (archetype.trim().isNotEmpty) return archetype.trim();
    if (deckName.trim().isNotEmpty) return deckName.trim();
    return 'Unknown';
  }
}

/// A settled match, in canonical (p1, p2) orientation.
class MatchFact {
  final String tournamentId;
  final String tournamentName;
  final DateTime date;

  /// '' when the organizer did not record one.
  final String format;

  /// '' when the tournament is not part of a series/league.
  final String series;
  final int round;
  final String matchId;
  final SideFact p1;
  final SideFact? p2; // null → bye
  final GameScore score; // a bye is recorded as 2-0, as in the standings engine
  final bool adjudicated; // the host set this result by hand
  final bool disputed; // it was escalated for review at some point

  const MatchFact({
    required this.tournamentId,
    required this.tournamentName,
    required this.date,
    required this.round,
    required this.matchId,
    required this.p1,
    required this.p2,
    required this.score,
    this.format = '',
    this.series = '',
    this.adjudicated = false,
    this.disputed = false,
  });

  bool get isBye => p2 == null;

  /// Label used for grouping by format; never empty.
  String get formatLabel =>
      format.trim().isEmpty ? 'Unspecified' : format.trim();

  bool get isDraw => !isBye && score.isDraw;

  bool involves(String playerId) =>
      p1.playerId == playerId || p2?.playerId == playerId;

  SideFact? sideOf(String playerId) {
    if (p1.playerId == playerId) return p1;
    if (p2?.playerId == playerId) return p2;
    return null;
  }

  SideFact? opponentOf(String playerId) {
    if (p1.playerId == playerId) return p2;
    if (p2?.playerId == playerId) return p1;
    return null;
  }

  bool usedDeck(String deckId) => p1.deckId == deckId || p2?.deckId == deckId;

  bool usedRevision(String revisionId) =>
      p1.revisionId == revisionId || p2?.revisionId == revisionId;

  bool usedArchetype(String archetype) =>
      p1.archetypeLabel == archetype || p2?.archetypeLabel == archetype;

  /// Outcome from [playerId]'s point of view. A bye is a match win.
  Outcome outcomeFor(String playerId) {
    if (isBye) return Outcome.win;
    if (score.isDraw) return Outcome.draw;
    final isP1 = p1.playerId == playerId;
    return (isP1 == score.p1IsWinner) ? Outcome.win : Outcome.loss;
  }

  /// Games won / lost / drawn by [playerId]. A bye counts as 2-0, matching the
  /// standings engine so game-win% never disagrees between screens.
  ({int won, int lost, int drawn}) gamesFor(String playerId) {
    if (isBye) return (won: 2, lost: 0, drawn: 0);
    final isP1 = p1.playerId == playerId;
    return (
      won: isP1 ? score.p1Wins : score.p2Wins,
      lost: isP1 ? score.p2Wins : score.p1Wins,
      drawn: score.draws,
    );
  }

  /// Flatten to the shape the Swiss standings engine consumes.
  MatchRecord get record => MatchRecord(p1.playerId, p2?.playerId, score);
}

/// The filter behind every Statistics screen control.
///
/// Absolute terms (date, format, tournament, series) narrow which matches are
/// considered. Subject-relative terms (player, deck, archetype, opponent) are
/// evaluated against a subject when one is supplied — "opponent = Ana" means
/// "matches where the subject faced Ana", not "any match Ana played".
class StatFilter {
  final DateTime? from;
  final DateTime? to;
  final String? format;
  final String? tournamentId;
  final String? series;
  final String? playerId;
  final String? deckId;
  final String? revisionId;
  final String? archetype;
  final String? opponentId;
  final String? opponentArchetype;

  /// Byes are real match wins but they distort matchup and deck rates, so the
  /// UI can drop them. Default keeps them, matching the standings.
  final bool includeByes;

  const StatFilter({
    this.from,
    this.to,
    this.format,
    this.tournamentId,
    this.series,
    this.playerId,
    this.deckId,
    this.revisionId,
    this.archetype,
    this.opponentId,
    this.opponentArchetype,
    this.includeByes = true,
  });

  bool get isEmpty =>
      from == null &&
      to == null &&
      _blank(format) &&
      _blank(tournamentId) &&
      _blank(series) &&
      _blank(playerId) &&
      _blank(deckId) &&
      _blank(revisionId) &&
      _blank(archetype) &&
      _blank(opponentId) &&
      _blank(opponentArchetype) &&
      includeByes;

  static bool _blank(String? s) => s == null || s.isEmpty;

  StatFilter copyWith({
    Object? from = _keep,
    Object? to = _keep,
    Object? format = _keep,
    Object? tournamentId = _keep,
    Object? series = _keep,
    Object? playerId = _keep,
    Object? deckId = _keep,
    Object? revisionId = _keep,
    Object? archetype = _keep,
    Object? opponentId = _keep,
    Object? opponentArchetype = _keep,
    bool? includeByes,
  }) => StatFilter(
    from: from == _keep ? this.from : from as DateTime?,
    to: to == _keep ? this.to : to as DateTime?,
    format: format == _keep ? this.format : format as String?,
    tournamentId: tournamentId == _keep
        ? this.tournamentId
        : tournamentId as String?,
    series: series == _keep ? this.series : series as String?,
    playerId: playerId == _keep ? this.playerId : playerId as String?,
    deckId: deckId == _keep ? this.deckId : deckId as String?,
    revisionId: revisionId == _keep ? this.revisionId : revisionId as String?,
    archetype: archetype == _keep ? this.archetype : archetype as String?,
    opponentId: opponentId == _keep ? this.opponentId : opponentId as String?,
    opponentArchetype: opponentArchetype == _keep
        ? this.opponentArchetype
        : opponentArchetype as String?,
    includeByes: includeByes ?? this.includeByes,
  );

  static const Object _keep = Object();

  /// True when [f] passes every set term. [subject] defaults to [playerId] and
  /// anchors the relative terms.
  bool matches(MatchFact f, {String? subject}) {
    final who = subject ?? playerId;
    if (!includeByes && f.isBye) return false;
    if (from != null && f.date.isBefore(from!)) return false;
    if (to != null && f.date.isAfter(to!)) return false;
    if (!_blank(format) && f.formatLabel != format) return false;
    if (!_blank(tournamentId) && f.tournamentId != tournamentId) return false;
    if (!_blank(series) && f.series != series) return false;
    if (!_blank(playerId) && !f.involves(playerId!)) return false;

    if (!_blank(deckId)) {
      final side = who == null ? null : f.sideOf(who);
      if (side != null ? side.deckId != deckId : !f.usedDeck(deckId!)) {
        return false;
      }
    }
    if (!_blank(revisionId)) {
      final side = who == null ? null : f.sideOf(who);
      if (side != null
          ? side.revisionId != revisionId
          : !f.usedRevision(revisionId!)) {
        return false;
      }
    }
    if (!_blank(archetype)) {
      final side = who == null ? null : f.sideOf(who);
      if (side != null
          ? side.archetypeLabel != archetype
          : !f.usedArchetype(archetype!)) {
        return false;
      }
    }
    if (!_blank(opponentId)) {
      if (who == null) {
        if (!f.involves(opponentId!)) return false;
      } else {
        if (f.opponentOf(who)?.playerId != opponentId) return false;
      }
    }
    if (!_blank(opponentArchetype)) {
      if (who == null) {
        if (!f.usedArchetype(opponentArchetype!)) return false;
      } else {
        if (f.opponentOf(who)?.archetypeLabel != opponentArchetype) {
          return false;
        }
      }
    }
    return true;
  }

  /// Narrow [facts] with this filter.
  List<MatchFact> apply(Iterable<MatchFact> facts, {String? subject}) => [
    for (final f in facts)
      if (matches(f, subject: subject)) f,
  ];
}

/// A Wilson score interval — the honest way to report a win rate from few
/// games. The naive 3/4 = 75% becomes "75% (95% CI 30–95%, n=4)".
class ConfidenceInterval {
  final double point;
  final double low;
  final double high;
  final int n;
  const ConfidenceInterval(this.point, this.low, this.high, this.n);

  /// Whether the sample is large enough to state as a finding rather than a
  /// hint. Callers should show the sample size either way.
  bool get reliable => n >= kReliableSample;

  /// Width of the interval — how much the number could still move.
  double get width => high - low;
}

/// Wilson score interval for [successes] out of [n] (draws counted as a half
/// success). Returns a full 0–1 interval for an empty sample.
ConfidenceInterval wilson(double successes, int n, {double z = 1.96}) {
  if (n <= 0) return const ConfidenceInterval(0, 0, 1, 0);
  final p = successes / n;
  final z2 = z * z;
  final denom = 1 + z2 / n;
  final centre = p + z2 / (2 * n);
  final margin = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n));
  final low = (centre - margin) / denom;
  final high = (centre + margin) / denom;
  return ConfidenceInterval(p, low < 0 ? 0 : low, high > 1 ? 1 : high, n);
}

/// Match record + game record for one subject, plus the sample-size honesty
/// that has to travel with them.
class Tally {
  final Record match = Record();
  final Record game = Record();

  /// Matches that were byes (free wins — reported separately so nobody mistakes
  /// a lucky pairing for a result).
  int byes = 0;

  /// Matches whose result the host set by hand.
  int adjudicated = 0;

  /// Matches that were escalated for review at some point.
  int disputed = 0;

  /// Fold one match into this tally from [playerId]'s point of view.
  void add(MatchFact f, String playerId) {
    match.add(f.outcomeFor(playerId));
    final g = f.gamesFor(playerId);
    game.wins += g.won;
    game.losses += g.lost;
    game.draws += g.drawn;
    if (f.isBye) byes++;
    if (f.adjudicated) adjudicated++;
    if (f.disputed) disputed++;
  }

  int get sampleSize => match.matches;
  bool get isEmpty => sampleSize == 0;

  /// Match-win rate counting a draw as half a win, with its interval.
  ConfidenceInterval get matchWin =>
      wilson(match.wins + match.draws / 2, match.matches);

  /// Game-win rate counting a drawn game as half, with its interval.
  ConfidenceInterval get gameWin =>
      wilson(game.wins + game.draws / 2, game.wins + game.losses + game.draws);

  bool get reliable => matchWin.reliable;

  @override
  String toString() => match.toString();
}

/// A run of identical results, newest-first ("W3" = winning three in a row).
class Streak {
  final Outcome kind;
  final int length;
  const Streak(this.kind, this.length);

  static const Streak none = Streak(Outcome.draw, 0);

  @override
  String toString() => switch (kind) {
    Outcome.win => 'W$length',
    Outcome.loss => 'L$length',
    Outcome.draw => length == 0 ? '—' : 'D$length',
  };
}

/// One time bucket of a trend series.
class PeriodTally {
  final String label; // "2026-08"
  final DateTime start;
  final Tally tally;
  const PeriodTally(this.label, this.start, this.tally);
}

/// Group [facts] into calendar-month buckets for [playerId], oldest first.
List<PeriodTally> monthlyTrend(Iterable<MatchFact> facts, String playerId) {
  final buckets = <String, PeriodTally>{};
  for (final f in facts) {
    if (!f.involves(playerId)) continue;
    final label = '${f.date.year}-${f.date.month.toString().padLeft(2, '0')}';
    final bucket = buckets.putIfAbsent(
      label,
      () => PeriodTally(label, DateTime(f.date.year, f.date.month), Tally()),
    );
    bucket.tally.add(f, playerId);
  }
  final out = buckets.values.toList()
    ..sort((a, b) => a.start.compareTo(b.start));
  return out;
}
