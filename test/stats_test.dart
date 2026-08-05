import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/stats.dart';

void main() {
  // Two tournaments with durable players (A,B,C,D) and named decks.
  final t1 = TournamentHistoryEntry(
    tournamentId: 't1',
    name: 'Friday Modern',
    date: DateTime(2026, 6, 1),
    deckByPlayer: const {'A': 'zoo', 'B': 'red', 'C': 'zoo', 'D': 'dimir'},
    records: const [
      MatchRecord('A', 'B', GameScore(2, 0)),
      MatchRecord('C', 'D', GameScore(2, 1)),
      MatchRecord('A', 'C', GameScore(2, 1)),
      MatchRecord('B', 'D', GameScore(2, 0)),
    ],
  );
  final t2 = TournamentHistoryEntry(
    tournamentId: 't2',
    name: 'Sunday Showdown',
    date: DateTime(2026, 6, 8),
    deckByPlayer: const {'A': 'zoo', 'B': 'red'},
    records: const [
      MatchRecord('A', 'B', GameScore(1, 2)), // red beats zoo
    ],
  );
  final stats = StatsEngine([t1, t2]);

  test('deck record aggregates across tournaments (incl. mirror)', () {
    final zoo = stats.deckRecord('zoo');
    expect([zoo.wins, zoo.losses, zoo.draws], [3, 2, 0]);
    expect(zoo.winRate, closeTo(0.6, 1e-9));

    final red = stats.deckRecord('red');
    expect([red.wins, red.losses], [2, 1]);
  });

  test('deck head-to-head is attributed correctly', () {
    final zooVsRed = stats.deckHeadToHead('zoo', 'red');
    expect([zooVsRed.wins, zooVsRed.losses], [1, 1]); // split across t1/t2
    final zooVsDimir = stats.deckHeadToHead('zoo', 'dimir');
    expect([zooVsDimir.wins, zooVsDimir.losses], [1, 0]);
  });

  test('player lifetime stats and tournament wins', () {
    final a = stats.playerLifetime('A');
    expect(a.tournamentsPlayed, 2);
    expect(a.tournamentsWon, 1); // won t1, lost t2 final
    expect([a.matchRecord.wins, a.matchRecord.losses], [2, 1]);
    expect(a.gameWinPct, closeTo(15 / 24, 1e-9));
  });

  test('timeline is newest-first', () {
    expect(stats.timeline.map((t) => t.tournamentId).toList(), ['t2', 't1']);
  });
}
