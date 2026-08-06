import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/rating.dart';
import 'package:mtg_tourney/shared/stats_facts.dart';
import 'package:mtg_tourney/shared/stats_service.dart';

import 'stats_fixture.dart';

/// Statistics formulas, filters, and the honesty rules around them: every rate
/// carries its sample size, byes and draws are counted the way the standings
/// count them, and nothing here claims more certainty than it has.
void main() {
  MatchFact fact({
    String tournamentId = 't1',
    String matchId = 'm1',
    int round = 1,
    String p1 = 'a',
    String? p2 = 'b',
    String p1Deck = 'da',
    String p2Deck = 'db',
    String p1Arch = 'Zoo',
    String p2Arch = 'Burn',
    GameScore score = const GameScore(2, 1),
    DateTime? date,
    String format = 'Modern',
    String series = '',
    bool adjudicated = false,
    bool disputed = false,
  }) => MatchFact(
    tournamentId: tournamentId,
    tournamentName: 'Event',
    date: date ?? DateTime.utc(2026, 3, 1),
    round: round,
    matchId: matchId,
    format: format,
    series: series,
    p1: SideFact(
      playerId: p1,
      deckId: p1Deck,
      revisionId: '$p1Deck:v1',
      deckName: p1Deck,
      archetype: p1Arch,
    ),
    p2: p2 == null
        ? null
        : SideFact(
            playerId: p2,
            deckId: p2Deck,
            revisionId: '$p2Deck:v1',
            deckName: p2Deck,
            archetype: p2Arch,
          ),
    score: score,
    adjudicated: adjudicated,
    disputed: disputed,
  );

  group('per-match arithmetic', () {
    test('a bye is a match win worth two games, as in the standings', () {
      final bye = fact(p2: null, score: const GameScore(2, 0));
      expect(bye.isBye, isTrue);
      expect(bye.outcomeFor('a'), Outcome.win);
      expect(bye.gamesFor('a'), (won: 2, lost: 0, drawn: 0));
    });

    test('a drawn match is a draw for both, from either orientation', () {
      final drawn = fact(score: const GameScore(1, 1, 1));
      expect(drawn.isDraw, isTrue);
      expect(drawn.outcomeFor('a'), Outcome.draw);
      expect(drawn.outcomeFor('b'), Outcome.draw);
      expect(drawn.gamesFor('b'), (won: 1, lost: 1, drawn: 1));
    });

    test('the loser sees the score flipped', () {
      final f = fact(score: const GameScore(2, 1));
      expect(f.outcomeFor('a'), Outcome.win);
      expect(f.outcomeFor('b'), Outcome.loss);
      expect(f.gamesFor('b'), (won: 1, lost: 2, drawn: 0));
    });
  });

  group('Wilson interval', () {
    test('an empty sample is the whole range, not 0%', () {
      final ci = wilson(0, 0);
      expect(ci.n, 0);
      expect(ci.low, 0);
      expect(ci.high, 1);
      expect(ci.reliable, isFalse);
    });

    test(
      'a small sample is wide; a large one narrows around the same rate',
      () {
        final few = wilson(3, 4);
        final many = wilson(75, 100);
        expect(few.point, closeTo(0.75, 1e-9));
        expect(many.point, closeTo(0.75, 1e-9));
        expect(many.width, lessThan(few.width));
        expect(few.reliable, isFalse);
        expect(many.reliable, isTrue);
      },
    );

    test('the interval always contains the point estimate', () {
      for (final n in [1, 5, 20, 100]) {
        for (var k = 0; k <= n; k++) {
          final ci = wilson(k.toDouble(), n);
          expect(ci.low, lessThanOrEqualTo(ci.point + 1e-9));
          expect(ci.high, greaterThanOrEqualTo(ci.point - 1e-9));
        }
      }
    });
  });

  group('Tally', () {
    test('separates byes, draws, disputes and adjudications', () {
      final t = Tally();
      t.add(fact(p2: null, score: const GameScore(2, 0)), 'a');
      t.add(fact(matchId: 'm2', score: const GameScore(1, 1, 1)), 'a');
      t.add(
        fact(matchId: 'm3', score: const GameScore(0, 2), disputed: true),
        'a',
      );
      t.add(
        fact(matchId: 'm4', score: const GameScore(2, 0), adjudicated: true),
        'a',
      );

      expect(t.sampleSize, 4);
      expect(t.match.wins, 2);
      expect(t.match.losses, 1);
      expect(t.match.draws, 1);
      expect(t.byes, 1);
      expect(t.disputed, 1);
      expect(t.adjudicated, 1);
      // Draws count as half a win in the rate, matching match points.
      expect(t.matchWin.point, closeTo(2.5 / 4, 1e-9));
      expect(t.reliable, isFalse); // four matches is not evidence
    });
  });

  group('StatFilter', () {
    final facts = [
      fact(
        matchId: 'm1',
        date: DateTime.utc(2026, 1, 10),
        format: 'Modern',
        series: 'Spring',
      ),
      fact(
        matchId: 'm2',
        tournamentId: 't2',
        date: DateTime.utc(2026, 5, 10),
        format: 'Legacy',
        p2: 'c',
        p2Deck: 'dc',
        p2Arch: 'Delver',
      ),
      fact(
        matchId: 'm3',
        tournamentId: 't3',
        p2: null,
        date: DateTime.utc(2026, 6, 1),
      ),
    ];

    test('narrows by date, format, series and tournament', () {
      expect(
        const StatFilter(format: 'Modern').apply(facts).map((f) => f.matchId),
        ['m1', 'm3'],
      );
      expect(
        const StatFilter(series: 'Spring').apply(facts).map((f) => f.matchId),
        ['m1'],
      );
      expect(
        StatFilter(
          from: DateTime.utc(2026, 4),
        ).apply(facts).map((f) => f.matchId),
        ['m2', 'm3'],
      );
      expect(
        const StatFilter(tournamentId: 't2').apply(facts).single.matchId,
        'm2',
      );
    });

    test('byes can be excluded', () {
      expect(
        const StatFilter(includeByes: false).apply(facts).map((f) => f.matchId),
        ['m1', 'm2'],
      );
    });

    test(
      'opponent is relative to the subject, not "any match they played"',
      () {
        // "a versus c" is only m2 — even though b also played a.
        final f = const StatFilter(playerId: 'a', opponentId: 'c');
        expect(f.apply(facts).map((x) => x.matchId), ['m2']);
        expect(
          const StatFilter(
            playerId: 'a',
            opponentArchetype: 'Delver',
          ).apply(facts).map((x) => x.matchId),
          ['m2'],
        );
      },
    );

    test('an empty filter is recognised as empty and changes nothing', () {
      expect(const StatFilter().isEmpty, isTrue);
      expect(const StatFilter().apply(facts), hasLength(3));
      expect(const StatFilter(format: 'Modern').isEmpty, isFalse);
    });

    test('copyWith can clear a term as well as set it', () {
      const set = StatFilter(format: 'Modern', playerId: 'a');
      expect(set.copyWith(format: null).format, isNull);
      expect(set.copyWith(format: null).playerId, 'a');
    });
  });

  group('matchup matrix', () {
    test('records both sides of each pairing and skips byes', () {
      final m = MatchupMatrix.from([
        fact(score: const GameScore(2, 0)),
        fact(matchId: 'm2', score: const GameScore(0, 2)),
        fact(matchId: 'm3', p2: null),
      ]);
      expect(m.cell('Zoo', 'Burn')!.match.wins, 1);
      expect(m.cell('Zoo', 'Burn')!.match.losses, 1);
      expect(m.cell('Burn', 'Zoo')!.match.wins, 1);
      expect(m.labels, containsAll(['Zoo', 'Burn']));
      expect(
        m.total('Zoo').match.matches,
        2,
        reason: 'the bye is not a matchup',
      );
    });
  });

  group('tournament report', () {
    test('counts byes, drops, disputes and adjudications for a real event', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy'], // odd field ⇒ byes every round
        archetypes: {'Ana': 'Zoo', 'Bo': 'Burn', 'Cy': 'Delver'},
      );

      final report = c.statistics.tournamentReport(
        ids.tournamentId,
        roster: c.rosterOf(ids.tournamentId),
        dropped: c.droppedIn(ids.tournamentId),
      );
      expect(report.playerCount, 3);
      expect(report.roundCount, greaterThan(1));
      expect(report.byes, greaterThan(0));
      expect(report.disputes, 0);
      expect(report.adjudications, 0);
      expect(
        report.archetypeCounts.keys,
        containsAll(['Zoo', 'Burn', 'Delver']),
      );
      // Ana is the strongest and must top the standings.
      expect(report.championId, ids.players['Ana']);
      // One rank per completed round, for every entrant.
      for (final id in ids.players.values) {
        expect(report.rankProgression[id], hasLength(report.roundCount));
      }
    });

    test('an adjudicated, disputed match is reported as both', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ana = enrol(c, 'Ana', deckName: 'Zoo');
      final bo = enrol(c, 'Bo', deckName: 'Burn');
      c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
      c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
      c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);
      c.startTournament();

      final m = firstRealMatch(c);
      // Players disagree, host settles it.
      c.submitResult(playerId: m.p1Id, matchId: m.id, mineWon: 2, oppWon: 0);
      c.submitResult(playerId: m.p2Id!, matchId: m.id, mineWon: 2, oppWon: 0);
      c.hostResolve(m.id, 2, 1, note: 'checked the slips');
      final id = c.engine!.id;
      c.clearTournament();

      final report = c.statistics.tournamentReport(id);
      expect(report.disputes, 1);
      expect(report.adjudications, 1);
    });
  });

  group('player report', () {
    test('tracks wins, average finish, streaks and monthly trend', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final first = runLeagueEvent(
        c,
        name: 'January',
        nicknames: ['Ana', 'Bo', 'Cy', 'Di'],
      );
      clock.advance(const Duration(days: 40));
      runLeagueEvent(c, name: 'February', nicknames: ['Ana', 'Bo', 'Cy', 'Di']);

      final ana = first.players['Ana']!;
      final report = c.statistics.playerReport(ana);
      expect(report.tournamentsPlayed, 2);
      expect(
        report.tournamentsWon,
        2,
        reason: 'Ana is strongest in the fixture',
      );
      expect(report.averageFinish, 1.0);
      expect(report.overall.match.losses, 0);
      expect(report.currentStreak.kind, Outcome.win);
      expect(report.currentStreak.length, report.recentForm.length);
      expect(report.byMonth, hasLength(2));
      expect(report.byMonth.first.label, '2026-01');
      // Head-to-head is populated for every opponent actually faced.
      expect(report.byOpponent.keys, isNotEmpty);
      for (final key in report.byOpponent.keys) {
        expect(key, isNot(ana));
      }
    });

    test('head-to-head is symmetric and sums to the matches played', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy', 'Di'],
      );
      final service = c.statistics;
      final ana = ids.players['Ana']!;
      final bo = ids.players['Bo']!;
      final forward = service.headToHead(ana, bo);
      final back = service.headToHead(bo, ana);
      expect(forward.match.matches, back.match.matches);
      expect(forward.match.wins, back.match.losses);
    });

    test('a filter narrows the report without touching the rating', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'Modern night',
        nicknames: ['Ana', 'Bo'],
        format: 'Modern',
      );
      clock.advance(const Duration(days: 7));
      runLeagueEvent(
        c,
        name: 'Legacy night',
        nicknames: ['Ana', 'Bo'],
        format: 'Legacy',
      );

      final ana = ids.players['Ana']!;
      final all = c.statistics.playerReport(ana);
      final modern = c.statistics.playerReport(
        ana,
        filter: const StatFilter(format: 'Modern'),
      );
      expect(all.overall.sampleSize, greaterThan(modern.overall.sampleSize));
      // The rating is deliberately computed over everything: a rating over a
      // filtered subset of games would not mean anything.
      expect(modern.ratingHistory.length, all.ratingHistory.length);
    });
  });

  group('deck report', () {
    test('splits a deck\'s record across its revisions', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runTwoPlayerEvent(c, name: 'One', aWins: 2, bWins: 0);
      final v1 = c.revisionsOf(ids.aDeck).single;

      // Rebuild the deck, play a second event with the new list.
      c.saveDeck(
        ownerId: ids.aId,
        deckId: ids.aDeck,
        name: 'Domain Zoo',
        mainboard: '4 Psychic Frog',
        sideboard: '',
      );
      clock.advance(const Duration(days: 7));
      c.createTournament(name: 'Two', hostPlayerId: ids.aId);
      c.joinTournament(playerId: ids.aId, deckId: ids.aDeck);
      c.joinTournament(playerId: ids.bId, deckId: ids.bDeck);
      c.startTournament();
      final m = firstRealMatch(c);
      final aIsP1 = m.p1Id == ids.aId;
      confirmMatch(c, m, aIsP1 ? 0 : 2, aIsP1 ? 2 : 0); // lost with v2
      c.clearTournament();

      final report = c.statistics.deckReport(ids.aDeck);
      expect(report.overall.match.matches, 2);
      expect(report.revisions, hasLength(2));
      expect(report.revisions.first.revision.id, v1.id);
      expect(report.revisions.first.tally.match.wins, 1);
      expect(report.revisions.last.tally.match.losses, 1);
      // The second revision knows what changed to produce it.
      final diff = report.revisions.last.changesFromPrevious!;
      expect(diff.main.added.keys, contains('Psychic Frog'));
      expect(diff.main.removed.keys, contains('Ragavan'));
      expect(report.placements, hasLength(2));
    });

    test('a revision report narrows to that exact list', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runTwoPlayerEvent(c, name: 'One');
      final v1 = c.revisionsOf(ids.aDeck).single;
      final narrowed = c.statistics.revisionReport(ids.aDeck, v1.id);
      expect(narrowed.overall.sampleSize, 1);
      expect(
        c.statistics
            .revisionReport(ids.aDeck, 'no-such-revision')
            .overall
            .sampleSize,
        0,
      );
    });
  });

  group('Glicko-2', () {
    test('a win raises the rating, a loss lowers it, both sharpen it', () {
      const start = Rating();
      final won = updateRating(start, [const RatedGame(Rating(), 1)]);
      final lost = updateRating(start, [const RatedGame(Rating(), 0)]);
      expect(won.rating, greaterThan(start.rating));
      expect(lost.rating, lessThan(start.rating));
      expect(won.deviation, lessThan(start.deviation));
      expect(lost.deviation, lessThan(start.deviation));
    });

    test('a draw against an equal opponent barely moves the rating', () {
      final drawn = updateRating(const Rating(), [
        const RatedGame(Rating(), 0.5),
      ]);
      expect(drawn.rating, closeTo(kDefaultRating, 1.0));
    });

    test('not playing widens the deviation but never past the default', () {
      final settled = Rating(
        rating: 1700,
        deviation: 60,
        volatility: kDefaultVolatility,
      );
      final idle = updateRating(settled, const []);
      expect(idle.rating, settled.rating);
      expect(idle.deviation, greaterThan(settled.deviation));
      expect(idle.deviation, lessThanOrEqualTo(kDefaultDeviation));
    });

    test('the conservative figure keeps a 1-match player off the top', () {
      final provisional = updateRating(const Rating(), [
        const RatedGame(Rating(), 1),
      ]);
      final established = Rating(rating: 1650, deviation: 50);
      expect(established.conservative, greaterThan(provisional.conservative));
      expect(established.established, isTrue);
      expect(provisional.established, isFalse);
    });

    test('history has one point per event and the winner ends on top', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'One',
        nicknames: ['Ana', 'Bo', 'Cy', 'Di'],
      );
      clock.advance(const Duration(days: 30));
      runLeagueEvent(c, name: 'Two', nicknames: ['Ana', 'Bo', 'Cy', 'Di']);

      final service = c.statistics;
      final ana = service.ratingHistory(ids.players['Ana']!);
      expect(ana, hasLength(2));
      expect(ana.last.rating.rating, greaterThan(ana.first.rating.rating));
      expect(ana.last.rating.deviation, lessThan(kDefaultDeviation));
      expect(service.leaderboard().first.playerId, ids.players['Ana']);
    });
  });

  group('the fact table rebuilds identically', () {
    test('after a save/load cycle, every statistic is unchanged', () {
      final clock = TestClock();
      final store = MemoryPersistence();
      final c = controllerWith(clock, store: store);
      final ids = runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy'],
      );

      final before = c.statistics.playerReport(ids.players['Ana']!);
      final restored = controllerWith(clock, store: store)..loadFromStore();
      final after = restored.statistics.playerReport(ids.players['Ana']!);

      expect(after.overall.match.wins, before.overall.match.wins);
      expect(after.overall.match.losses, before.overall.match.losses);
      expect(after.overall.game.wins, before.overall.game.wins);
      expect(after.tournamentsWon, before.tournamentsWon);
      expect(after.averageFinish, before.averageFinish);
      expect(
        after.ratingHistory.last.rating.rating,
        closeTo(before.ratingHistory.last.rating.rating, 1e-9),
      );
      expect(restored.statistics.facts.length, c.statistics.facts.length);
    });

    test('facts are ordered deterministically regardless of input order', () {
      final a = fact(matchId: 'm1', round: 1);
      final b = fact(matchId: 'm2', round: 2);
      expect(
        StatsService([b, a]).facts.map((f) => f.matchId),
        StatsService([a, b]).facts.map((f) => f.matchId),
      );
    });
  });
}
