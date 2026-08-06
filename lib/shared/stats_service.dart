/// Typed statistics services: every number the app shows is produced here, not
/// in a widget.
///
/// Everything is a fold over [MatchFact]s, so a report is a pure function of
/// (facts, filter, subject) and can be tested without a device, a database or a
/// running tournament. Rates always travel with their sample size — see
/// [Tally.matchWin] — because a 3-1 record is not a 75% deck.
///
/// Nothing here infers causation. A matchup number says "when these two decks
/// met, this happened", not why.
///
/// PURE DART (no I/O, no Flutter, no clock).
library;

import 'deck_revision.dart';
import 'models.dart';
import 'rating.dart';
import 'stats_facts.dart';
import 'swiss.dart';

/// Archetype-versus-archetype records, row = the archetype whose point of view
/// the record is from.
class MatchupMatrix {
  final Map<String, Map<String, Tally>> rows;
  const MatchupMatrix(this.rows);

  /// Every archetype appearing as a row, most-played first then alphabetical.
  List<String> get labels {
    final ls = rows.keys.toList();
    ls.sort((a, b) {
      final na = rows[a]!.values.fold(0, (s, t) => s + t.sampleSize);
      final nb = rows[b]!.values.fold(0, (s, t) => s + t.sampleSize);
      return na == nb ? a.compareTo(b) : nb.compareTo(na);
    });
    return ls;
  }

  Tally? cell(String row, String column) => rows[row]?[column];

  /// Total record for [row] across all opponents.
  Tally total(String row) {
    final t = Tally();
    for (final cell in rows[row]?.values ?? const <Tally>[]) {
      t.match.wins += cell.match.wins;
      t.match.losses += cell.match.losses;
      t.match.draws += cell.match.draws;
      t.game.wins += cell.game.wins;
      t.game.losses += cell.game.losses;
      t.game.draws += cell.game.draws;
    }
    return t;
  }

  bool get isEmpty => rows.isEmpty;

  /// Build from non-bye facts, keyed by [SideFact.archetypeLabel].
  factory MatchupMatrix.from(Iterable<MatchFact> facts) {
    final rows = <String, Map<String, Tally>>{};
    void put(String row, String col, MatchFact f, String playerId) {
      rows
          .putIfAbsent(row, () => {})
          .putIfAbsent(col, () => Tally())
          .add(f, playerId);
    }

    for (final f in facts) {
      final p2 = f.p2;
      if (p2 == null) continue; // a bye has no matchup
      put(f.p1.archetypeLabel, p2.archetypeLabel, f, f.p1.playerId);
      put(p2.archetypeLabel, f.p1.archetypeLabel, f, p2.playerId);
    }
    return MatchupMatrix(rows);
  }
}

/// One round of a tournament, as history sees it.
class RoundReport {
  final int number;
  final List<MatchFact> matches;
  const RoundReport(this.number, this.matches);

  int get byes => matches.where((m) => m.isBye).length;
  int get draws => matches.where((m) => m.isDraw).length;
}

/// Where a player finished one event, and how they did in it.
class TournamentPlacement {
  final String tournamentId;
  final String tournamentName;
  final DateTime date;
  final String format;
  final String series;
  final int rank;
  final int playerCount;
  final Tally tally;

  /// The deck (and exact revision) they brought, when known.
  final String deckId;
  final String revisionId;
  final String archetype;

  const TournamentPlacement({
    required this.tournamentId,
    required this.tournamentName,
    required this.date,
    required this.rank,
    required this.playerCount,
    required this.tally,
    this.format = '',
    this.series = '',
    this.deckId = '',
    this.revisionId = '',
    this.archetype = '',
  });

  bool get isWin => rank == 1;
}

/// Everything the tournament screen shows, computed once.
class TournamentReport {
  final String tournamentId;
  final String name;
  final DateTime date;
  final String format;
  final String series;
  final int roundCount;
  final List<String> playerIds;
  final List<StandingRow> standings;
  final List<RoundReport> rounds;

  /// playerId → rank after each completed round (index 0 = after round 1).
  final Map<String, List<int>> rankProgression;
  final Map<String, int> archetypeCounts;
  final Map<String, int> deckCounts;
  final MatchupMatrix matchups;
  final Map<String, Tally> playerTallies;
  final Map<String, Tally> deckTallies;
  final int byes;
  final int draws;
  final int drops;
  final int disputes;
  final int adjudications;

  const TournamentReport({
    required this.tournamentId,
    required this.name,
    required this.date,
    required this.format,
    required this.series,
    required this.roundCount,
    required this.playerIds,
    required this.standings,
    required this.rounds,
    required this.rankProgression,
    required this.archetypeCounts,
    required this.deckCounts,
    required this.matchups,
    required this.playerTallies,
    required this.deckTallies,
    required this.byes,
    required this.draws,
    required this.drops,
    required this.disputes,
    required this.adjudications,
  });

  int get playerCount => playerIds.length;
  String? get championId => standings.isEmpty ? null : standings.first.playerId;
}

/// Cross-tournament view of one durable player identity.
class PlayerReport {
  final String playerId;
  final Tally overall;
  final int tournamentsPlayed;
  final int tournamentsWon;

  /// Mean finishing rank; null when they have no completed placement.
  final double? averageFinish;
  final List<TournamentPlacement> placements; // newest first
  final Map<String, Tally> byDeck;
  final Map<String, Tally> byArchetype;
  final Map<String, Tally> byFormat;
  final Map<String, Tally> byOpponent; // head-to-head
  final Map<String, Tally> byOpponentArchetype;
  final List<PeriodTally> byMonth;
  final List<RatingPoint> ratingHistory;

  /// Most recent match outcomes, newest first (capped by the caller).
  final List<Outcome> recentForm;
  final Streak currentStreak;
  final Streak longestWinStreak;

  const PlayerReport({
    required this.playerId,
    required this.overall,
    required this.tournamentsPlayed,
    required this.tournamentsWon,
    required this.averageFinish,
    required this.placements,
    required this.byDeck,
    required this.byArchetype,
    required this.byFormat,
    required this.byOpponent,
    required this.byOpponentArchetype,
    required this.byMonth,
    required this.ratingHistory,
    required this.recentForm,
    required this.currentStreak,
    required this.longestWinStreak,
  });

  Rating get rating =>
      ratingHistory.isEmpty ? const Rating() : ratingHistory.last.rating;

  double get winPercent => overall.matchWin.point;
}

/// One revision's record, plus what changed to get to it.
class RevisionStanding {
  final DeckRevision revision;
  final Tally tally;

  /// Diff against the previous revision of the same deck; null for the first.
  final DeckDiff? changesFromPrevious;
  const RevisionStanding(this.revision, this.tally, this.changesFromPrevious);
}

/// Cross-tournament view of one deck and each of its revisions.
class DeckReport {
  final String deckId;
  final Tally overall;
  final List<RevisionStanding> revisions; // oldest first
  final Map<String, Tally> byFormat;
  final Map<String, Tally> byOpponentArchetype;
  final List<PeriodTally> byMonth;
  final List<TournamentPlacement> placements; // newest first
  final MatchupMatrix matchups;

  const DeckReport({
    required this.deckId,
    required this.overall,
    required this.revisions,
    required this.byFormat,
    required this.byOpponentArchetype,
    required this.byMonth,
    required this.placements,
    required this.matchups,
  });

  /// True when some of this deck's history predates deck revisions, so the
  /// list shown for those events is the deck's current list, not a proven one.
  bool get hasMigratedHistory => revisions.any((r) => r.revision.migrated);
}

/// Query surface over a fact table. Construct once per screen; the reports are
/// plain data, so widgets only ever read fields.
class StatsService {
  final List<MatchFact> facts;

  /// Revisions by id, so deck reports can diff them. Optional.
  final Map<String, DeckRevision> revisions;

  StatsService(Iterable<MatchFact> facts, {this.revisions = const {}})
    : facts = List.unmodifiable(
        [...facts]..sort((a, b) {
          final byDate = a.date.compareTo(b.date);
          if (byDate != 0) return byDate;
          final byTournament = a.tournamentId.compareTo(b.tournamentId);
          if (byTournament != 0) return byTournament;
          final byRound = a.round.compareTo(b.round);
          return byRound != 0 ? byRound : a.matchId.compareTo(b.matchId);
        }),
      );

  /// Facts narrowed by [filter], anchored on [subject] for relative terms.
  List<MatchFact> where(StatFilter filter, {String? subject}) =>
      filter.apply(facts, subject: subject);

  // ---- distinct values, for the filter controls ------------------------

  List<String> get formats => _distinct(facts.map((f) => f.formatLabel));

  List<String> get seriesNames =>
      _distinct(facts.where((f) => f.series.isNotEmpty).map((f) => f.series));

  List<String> get archetypes => _distinct([
    for (final f in facts) ...[
      f.p1.archetypeLabel,
      if (f.p2 != null) f.p2!.archetypeLabel,
    ],
  ]);

  List<String> get playerIds => _distinct([
    for (final f in facts) ...[f.p1.playerId, if (f.p2 != null) f.p2!.playerId],
  ]);

  static List<String> _distinct(Iterable<String> xs) =>
      xs.toSet().toList()..sort();

  /// Tournaments present in the fact table, newest first.
  List<({String id, String name, DateTime date, String format, String series})>
  get tournaments {
    final seen =
        <
          String,
          ({
            String id,
            String name,
            DateTime date,
            String format,
            String series,
          })
        >{};
    for (final f in facts) {
      seen[f.tournamentId] ??= (
        id: f.tournamentId,
        name: f.tournamentName,
        date: f.date,
        format: f.format,
        series: f.series,
      );
    }
    final out = seen.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  // ---- tournament ------------------------------------------------------

  /// Full report for one event. [roster] adds entrants who never had a settled
  /// match (so the player count is the real one), and [dropped] marks drops.
  TournamentReport tournamentReport(
    String tournamentId, {
    Iterable<String> roster = const [],
    Iterable<String> dropped = const [],
  }) {
    final own = [
      for (final f in facts)
        if (f.tournamentId == tournamentId) f,
    ];
    final first = own.isEmpty ? null : own.first;
    final ids = <String>{...roster};
    for (final f in own) {
      ids.add(f.p1.playerId);
      if (f.p2 != null) ids.add(f.p2!.playerId);
    }

    final roundCount = own.fold(0, (m, f) => f.round > m ? f.round : m);
    final rounds = [
      for (var r = 1; r <= roundCount; r++)
        RoundReport(r, [
          for (final f in own)
            if (f.round == r) f,
        ]),
    ];

    final progression = <String, List<int>>{for (final id in ids) id: []};
    for (var r = 1; r <= roundCount; r++) {
      final upTo = [
        for (final f in own)
          if (f.round <= r) f.record,
      ];
      final standings = computeStandings(upTo, ids);
      for (var i = 0; i < standings.length; i++) {
        progression[standings[i].playerId]?.add(i + 1);
      }
    }

    final playerTallies = <String, Tally>{};
    final deckTallies = <String, Tally>{};
    final archetypeCounts = <String, int>{};
    final deckCounts = <String, int>{};
    final seenEntry = <String>{};
    for (final f in own) {
      for (final side in [f.p1, if (f.p2 != null) f.p2!]) {
        playerTallies
            .putIfAbsent(side.playerId, Tally.new)
            .add(f, side.playerId);
        if (side.deckId.isNotEmpty) {
          deckTallies.putIfAbsent(side.deckId, Tally.new).add(f, side.playerId);
        }
        if (seenEntry.add(side.playerId)) {
          archetypeCounts[side.archetypeLabel] =
              (archetypeCounts[side.archetypeLabel] ?? 0) + 1;
          if (side.deckId.isNotEmpty) {
            deckCounts[side.deckId] = (deckCounts[side.deckId] ?? 0) + 1;
          }
        }
      }
    }

    return TournamentReport(
      tournamentId: tournamentId,
      name: first?.tournamentName ?? '',
      date: first?.date ?? DateTime.fromMillisecondsSinceEpoch(0),
      format: first?.format ?? '',
      series: first?.series ?? '',
      roundCount: roundCount,
      playerIds: ids.toList()..sort(),
      standings: computeStandings([for (final f in own) f.record], ids),
      rounds: rounds,
      rankProgression: progression,
      archetypeCounts: archetypeCounts,
      deckCounts: deckCounts,
      matchups: MatchupMatrix.from(own),
      playerTallies: playerTallies,
      deckTallies: deckTallies,
      byes: own.where((f) => f.isBye).length,
      draws: own.where((f) => f.isDraw).length,
      drops: dropped.length,
      disputes: own.where((f) => f.disputed).length,
      adjudications: own.where((f) => f.adjudicated).length,
    );
  }

  /// Final rank of every player in [tournamentId], 1-based.
  Map<String, int> finalRanks(String tournamentId) {
    final own = [
      for (final f in facts)
        if (f.tournamentId == tournamentId) f,
    ];
    final ids = <String>{};
    for (final f in own) {
      ids.add(f.p1.playerId);
      if (f.p2 != null) ids.add(f.p2!.playerId);
    }
    final standings = computeStandings([for (final f in own) f.record], ids);
    return {
      for (var i = 0; i < standings.length; i++) standings[i].playerId: i + 1,
    };
  }

  // ---- player ----------------------------------------------------------

  PlayerReport playerReport(
    String playerId, {
    StatFilter filter = const StatFilter(),
    int formLength = 10,
  }) {
    final own = [
      for (final f in where(filter, subject: playerId))
        if (f.involves(playerId)) f,
    ];

    final overall = Tally();
    final byDeck = <String, Tally>{};
    final byArchetype = <String, Tally>{};
    final byFormat = <String, Tally>{};
    final byOpponent = <String, Tally>{};
    final byOpponentArchetype = <String, Tally>{};

    for (final f in own) {
      final me = f.sideOf(playerId)!;
      overall.add(f, playerId);
      byFormat.putIfAbsent(f.formatLabel, Tally.new).add(f, playerId);
      if (me.deckId.isNotEmpty) {
        byDeck.putIfAbsent(me.deckId, Tally.new).add(f, playerId);
      }
      byArchetype.putIfAbsent(me.archetypeLabel, Tally.new).add(f, playerId);
      final opp = f.opponentOf(playerId);
      if (opp != null) {
        byOpponent.putIfAbsent(opp.playerId, Tally.new).add(f, playerId);
        byOpponentArchetype
            .putIfAbsent(opp.archetypeLabel, Tally.new)
            .add(f, playerId);
      }
    }

    final placements = _placementsFor(playerId, own);
    final finishes = [for (final p in placements) p.rank];

    // Newest first, and only real matches — a bye says nothing about form.
    final ordered = [...own]..sort(_chronological);
    final form = [
      for (final f in ordered.reversed)
        if (!f.isBye) f.outcomeFor(playerId),
    ];

    return PlayerReport(
      playerId: playerId,
      overall: overall,
      tournamentsPlayed: own.map((f) => f.tournamentId).toSet().length,
      tournamentsWon: placements.where((p) => p.isWin).length,
      averageFinish: finishes.isEmpty
          ? null
          : finishes.reduce((a, b) => a + b) / finishes.length,
      placements: placements,
      byDeck: byDeck,
      byArchetype: byArchetype,
      byFormat: byFormat,
      byOpponent: byOpponent,
      byOpponentArchetype: byOpponentArchetype,
      byMonth: monthlyTrend(own, playerId),
      ratingHistory: ratingHistory(playerId),
      recentForm: form.take(formLength).toList(),
      currentStreak: _streakOf(form),
      longestWinStreak: _longestStreak(form, Outcome.win),
    );
  }

  /// Head-to-head record of [playerId] against [opponentId].
  Tally headToHead(
    String playerId,
    String opponentId, {
    StatFilter filter = const StatFilter(),
  }) {
    final t = Tally();
    for (final f in where(filter, subject: playerId)) {
      if (f.opponentOf(playerId)?.playerId == opponentId) t.add(f, playerId);
    }
    return t;
  }

  // ---- deck ------------------------------------------------------------

  DeckReport deckReport(
    String deckId, {
    StatFilter filter = const StatFilter(),
  }) {
    final own = [
      for (final f in where(filter))
        if (f.usedDeck(deckId)) f,
    ];

    final overall = Tally();
    final byRevision = <String, Tally>{};
    final byFormat = <String, Tally>{};
    final byOpponentArchetype = <String, Tally>{};
    final months = <String, PeriodTally>{};
    final relevant = <MatchFact>[];

    for (final f in own) {
      for (final side in [f.p1, if (f.p2 != null) f.p2!]) {
        if (side.deckId != deckId) continue;
        relevant.add(f);
        overall.add(f, side.playerId);
        byFormat.putIfAbsent(f.formatLabel, Tally.new).add(f, side.playerId);
        if (side.revisionId.isNotEmpty) {
          byRevision
              .putIfAbsent(side.revisionId, Tally.new)
              .add(f, side.playerId);
        }
        final opp = f.opponentOf(side.playerId);
        if (opp != null) {
          byOpponentArchetype
              .putIfAbsent(opp.archetypeLabel, Tally.new)
              .add(f, side.playerId);
        }
        final label =
            '${f.date.year}-${f.date.month.toString().padLeft(2, '0')}';
        months
            .putIfAbsent(
              label,
              () => PeriodTally(
                label,
                DateTime(f.date.year, f.date.month),
                Tally(),
              ),
            )
            .tally
            .add(f, side.playerId);
      }
    }

    // Revisions of this deck, oldest first, each with the diff that made it.
    final mine =
        [
          for (final r in revisions.values)
            if (r.deckId == deckId) r,
        ]..sort((a, b) {
          final byOrdinal = a.revision.compareTo(b.revision);
          return byOrdinal != 0
              ? byOrdinal
              : a.createdAt.compareTo(b.createdAt);
        });
    final standings = <RevisionStanding>[];
    for (var i = 0; i < mine.length; i++) {
      standings.add(
        RevisionStanding(
          mine[i],
          byRevision[mine[i].id] ?? Tally(),
          i == 0 ? null : DeckDiff.between(mine[i - 1], mine[i]),
        ),
      );
    }

    final monthly = months.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    return DeckReport(
      deckId: deckId,
      overall: overall,
      revisions: standings,
      byFormat: byFormat,
      byOpponentArchetype: byOpponentArchetype,
      byMonth: monthly,
      placements: _deckPlacements(deckId, relevant),
      matchups: MatchupMatrix.from(relevant),
    );
  }

  /// The same report narrowed to one exact revision — "how did *this* 75 do".
  DeckReport revisionReport(
    String deckId,
    String revisionId, {
    StatFilter filter = const StatFilter(),
  }) => deckReport(deckId, filter: filter.copyWith(revisionId: revisionId));

  // ---- ratings ---------------------------------------------------------

  /// Glicko-2 history for every player, one rating period per tournament in
  /// chronological order. Computed over the **whole** fact table on purpose: a
  /// rating filtered to a subset of a player's games would be meaningless.
  Map<String, List<RatingPoint>> ratingHistories() {
    final current = <String, Rating>{};
    final history = <String, List<RatingPoint>>{};

    final byTournament = <String, List<MatchFact>>{};
    for (final f in facts) {
      byTournament.putIfAbsent(f.tournamentId, () => []).add(f);
    }
    final ordered = byTournament.entries.toList()
      ..sort((a, b) {
        final byDate = a.value.first.date.compareTo(b.value.first.date);
        return byDate != 0 ? byDate : a.key.compareTo(b.key);
      });

    for (final entry in ordered) {
      final games = <String, List<RatedGame>>{};
      for (final f in entry.value) {
        if (f.isBye) continue; // no opponent, nothing to learn
        final a = f.p1.playerId;
        final b = f.p2!.playerId;
        current.putIfAbsent(a, Rating.new);
        current.putIfAbsent(b, Rating.new);
        final scoreA = f.score.isDraw ? 0.5 : (f.score.p1IsWinner ? 1.0 : 0.0);
        games.putIfAbsent(a, () => []).add(RatedGame(current[b]!, scoreA));
        games.putIfAbsent(b, () => []).add(RatedGame(current[a]!, 1 - scoreA));
      }
      final updated = <String, Rating>{};
      for (final playerId in games.keys) {
        updated[playerId] = updateRating(
          current[playerId] ?? const Rating(),
          games[playerId]!,
        );
      }
      current.addAll(updated);
      for (final playerId in games.keys) {
        history
            .putIfAbsent(playerId, () => [])
            .add(
              RatingPoint(
                tournamentId: entry.key,
                tournamentName: entry.value.first.tournamentName,
                date: entry.value.first.date,
                rating: current[playerId]!,
                matches: games[playerId]!.length,
              ),
            );
      }
    }
    return history;
  }

  List<RatingPoint> _ratingCache(String playerId) =>
      (_ratings ??= ratingHistories())[playerId] ?? const [];
  Map<String, List<RatingPoint>>? _ratings;

  List<RatingPoint> ratingHistory(String playerId) => _ratingCache(playerId);

  /// Current rating leaderboard, most conservative-first so a 2-match 1900
  /// does not outrank a 40-match 1750.
  List<({String playerId, Rating rating, int matches})> leaderboard() {
    final all = ratingHistories();
    final rows = [
      for (final e in all.entries)
        (
          playerId: e.key,
          rating: e.value.last.rating,
          matches: e.value.fold(0, (s, p) => s + p.matches),
        ),
    ];
    rows.sort((a, b) => b.rating.conservative.compareTo(a.rating.conservative));
    return rows;
  }

  // ---- internals -------------------------------------------------------

  static int _chronological(MatchFact a, MatchFact b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byTournament = a.tournamentId.compareTo(b.tournamentId);
    if (byTournament != 0) return byTournament;
    final byRound = a.round.compareTo(b.round);
    return byRound != 0 ? byRound : a.matchId.compareTo(b.matchId);
  }

  List<TournamentPlacement> _placementsFor(
    String playerId,
    List<MatchFact> own,
  ) {
    final byTournament = <String, List<MatchFact>>{};
    for (final f in own) {
      byTournament.putIfAbsent(f.tournamentId, () => []).add(f);
    }
    final out = <TournamentPlacement>[];
    for (final e in byTournament.entries) {
      final ranks = finalRanks(e.key);
      final rank = ranks[playerId];
      if (rank == null) continue;
      final tally = Tally();
      for (final f in e.value) {
        tally.add(f, playerId);
      }
      final head = e.value.first;
      final side = head.sideOf(playerId);
      out.add(
        TournamentPlacement(
          tournamentId: e.key,
          tournamentName: head.tournamentName,
          date: head.date,
          format: head.format,
          series: head.series,
          rank: rank,
          playerCount: ranks.length,
          tally: tally,
          deckId: side?.deckId ?? '',
          revisionId: side?.revisionId ?? '',
          archetype: side?.archetypeLabel ?? '',
        ),
      );
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  List<TournamentPlacement> _deckPlacements(
    String deckId,
    List<MatchFact> relevant,
  ) {
    // A deck belongs to one owner, but an imported history may show several
    // players on the same deck id; report each (player, event) placement once.
    final seen = <String>{};
    final out = <TournamentPlacement>[];
    for (final f in relevant) {
      for (final side in [f.p1, if (f.p2 != null) f.p2!]) {
        if (side.deckId != deckId) continue;
        if (!seen.add('${f.tournamentId}/${side.playerId}')) continue;
        final ranks = finalRanks(f.tournamentId);
        final rank = ranks[side.playerId];
        if (rank == null) continue;
        final tally = Tally();
        for (final g in relevant) {
          if (g.tournamentId == f.tournamentId && g.involves(side.playerId)) {
            tally.add(g, side.playerId);
          }
        }
        out.add(
          TournamentPlacement(
            tournamentId: f.tournamentId,
            tournamentName: f.tournamentName,
            date: f.date,
            format: f.format,
            series: f.series,
            rank: rank,
            playerCount: ranks.length,
            tally: tally,
            deckId: deckId,
            revisionId: side.revisionId,
            archetype: side.archetypeLabel,
          ),
        );
      }
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  static Streak _streakOf(List<Outcome> newestFirst) {
    if (newestFirst.isEmpty) return Streak.none;
    final kind = newestFirst.first;
    var n = 0;
    for (final o in newestFirst) {
      if (o != kind) break;
      n++;
    }
    return Streak(kind, n);
  }

  static Streak _longestStreak(List<Outcome> outcomes, Outcome kind) {
    var best = 0;
    var run = 0;
    for (final o in outcomes) {
      run = (o == kind) ? run + 1 : 0;
      if (run > best) best = run;
    }
    return Streak(kind, best);
  }
}
