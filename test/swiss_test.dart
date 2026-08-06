import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/swiss.dart';

void main() {
  group('recommendedRounds (MTR App. E)', () {
    test('boundaries', () {
      expect(recommendedRounds(1), 0);
      expect(recommendedRounds(2), 1);
      expect(recommendedRounds(4), 2);
      expect(recommendedRounds(8), 3);
      expect(recommendedRounds(9), 4);
      expect(recommendedRounds(16), 4);
      expect(recommendedRounds(17), 5);
      expect(recommendedRounds(32), 5);
      expect(recommendedRounds(33), 6);
      expect(recommendedRounds(64), 6);
      expect(recommendedRounds(65), 7);
      expect(recommendedRounds(200), 8);
    });
  });

  group('pairRound', () {
    test('8 players: 4 pairs, no bye, everyone paired once', () {
      final players = [for (var i = 0; i < 8; i++) 'p$i'];
      final r = pairRound(orderedPlayers: players, playedKeys: {}, hadBye: {});
      expect(r.bye, isNull);
      expect(r.pairs.length, 4);
      final seen = r.pairs.expand((p) => p).toSet();
      expect(seen, players.toSet());
      expect(r.forcedRematch, isFalse);
    });

    test('odd field: exactly one bye to the lowest eligible player', () {
      final players = ['p0', 'p1', 'p2', 'p3', 'p4'];
      final r = pairRound(orderedPlayers: players, playedKeys: {}, hadBye: {});
      expect(r.bye, 'p4'); // last in order, never byed
      expect(r.pairs.length, 2);
      final seen = r.pairs.expand((p) => p).toSet();
      expect(seen, {'p0', 'p1', 'p2', 'p3'});
    });

    test('does not give a second bye while someone is un-byed', () {
      final players = ['p0', 'p1', 'p2', 'p3', 'p4'];
      final r = pairRound(
        orderedPlayers: players,
        playedKeys: {},
        hadBye: {'p4'},
      );
      expect(r.bye, 'p3'); // p4 already had one
    });

    test('avoids a rematch via backtracking', () {
      // A&B and C&D already played in round 1.
      final played = {pairKey('A', 'B'), pairKey('C', 'D')};
      final r = pairRound(
        orderedPlayers: ['A', 'B', 'C', 'D'],
        playedKeys: played,
        hadBye: {},
      );
      expect(r.forcedRematch, isFalse);
      for (final pair in r.pairs) {
        expect(
          played.contains(pairKey(pair[0], pair[1])),
          isFalse,
          reason: 'pair ${pair[0]}-${pair[1]} is a rematch',
        );
      }
    });
  });

  group('computeStandings (MTR App. C tiebreakers)', () {
    test('4-player, 2-round scenario ranks and tiebreaks correctly', () {
      final records = [
        const MatchRecord('A', 'B', GameScore(2, 0)),
        const MatchRecord('C', 'D', GameScore(2, 1)),
        const MatchRecord('A', 'C', GameScore(2, 1)),
        const MatchRecord('B', 'D', GameScore(2, 0)),
      ];
      final s = computeStandings(records, ['A', 'B', 'C', 'D']);
      final byId = {for (final r in s) r.playerId: r};

      expect(byId['A']!.matchPoints, 6);
      expect(byId['B']!.matchPoints, 3);
      expect(byId['C']!.matchPoints, 3);
      expect(byId['D']!.matchPoints, 0);

      // A's opponents (B, C) each have MWP 0.5 -> OMW 0.5.
      expect(byId['A']!.omw, closeTo(0.5, 1e-9));
      // B's opponents (A=1.0, D=floored 0.3333) -> ~0.6667.
      expect(byId['B']!.omw, closeTo((1.0 + 1 / 3) / 2, 1e-9));
      // A's game-win%: 12 game points / 15 -> 0.8.
      expect(byId['A']!.gw, closeTo(0.8, 1e-9));
      // D floored on GW% (3/15 = 0.2 -> 0.3333).
      expect(byId['D']!.gw, closeTo(1 / 3, 1e-9));

      // Final order: A (6) > B (3, id<C on the last tiebreak) > C > D (0).
      expect(s.map((r) => r.playerId).toList(), ['A', 'B', 'C', 'D']);
    });

    test('a bye scores 3 points and counts as 2-0, with no opponent', () {
      final records = [
        const MatchRecord('A', 'B', GameScore(2, 0)),
        const MatchRecord('C', null, GameScore(2, 0)), // bye
      ];
      final s = computeStandings(records, ['A', 'B', 'C']);
      final byId = {for (final r in s) r.playerId: r};
      expect(byId['C']!.matchPoints, 3);
      expect(byId['C']!.byes, 1);
      expect(byId['A']!.matchPoints, 3);
      expect(byId['B']!.matchPoints, 0);
      // A beat a real opponent (OMW 0.3333) and outranks C (no opponents, OMW 0).
      final order = s.map((r) => r.playerId).toList();
      expect(order.indexOf('A'), lessThan(order.indexOf('C')));
    });
  });
}
