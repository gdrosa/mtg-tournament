/// Cross-tournament statistics over durable player & deck identities.
///
/// This is the read model behind the Profile/Decks/Events screens and the
/// "history with dates and statistics" requirement (FR-43/44/45, REQUIREMENTS
/// Q1 = durable identity). Pure Dart so it is unit-testable on Windows; the
/// durable store (Drift/SQLite) will feed [history] into it.
library;

import 'models.dart';
import 'swiss.dart';

/// One finished (or in-progress) tournament's results, tagged with the deck
/// each player brought, so results can be attributed per named deck.
class TournamentHistoryEntry {
  final String tournamentId;
  final String name;
  final DateTime date;
  final List<MatchRecord> records; // byes included
  final Map<String, String> deckByPlayer; // playerId -> deckId used here
  const TournamentHistoryEntry({
    required this.tournamentId,
    required this.name,
    required this.date,
    required this.records,
    required this.deckByPlayer,
  });

  Iterable<String> get players => deckByPlayer.keys;
}

enum Outcome { win, loss, draw }

/// Win/loss/draw tally with derived rates.
class Record {
  int wins;
  int losses;
  int draws;
  Record([this.wins = 0, this.losses = 0, this.draws = 0]);

  int get matches => wins + losses + draws;
  double get winRate => matches == 0 ? 0 : wins / matches;

  void add(Outcome o) => switch (o) {
    Outcome.win => wins++,
    Outcome.loss => losses++,
    Outcome.draw => draws++,
  };

  @override
  String toString() => '$wins-$losses${draws > 0 ? '-$draws' : ''}';
}

class PlayerLifetime {
  final String playerId;
  final int tournamentsPlayed;
  final int tournamentsWon;
  final Record matchRecord;
  final double gameWinPct;
  const PlayerLifetime({
    required this.playerId,
    required this.tournamentsPlayed,
    required this.tournamentsWon,
    required this.matchRecord,
    required this.gameWinPct,
  });
}

/// Compute the outcome of [record] from [playerId]'s perspective.
Outcome outcomeFor(String playerId, MatchRecord record) {
  if (record.isBye) return Outcome.win; // a bye is a free match win
  final s = record.score;
  if (s.isDoubleLoss) return Outcome.loss; // both disqualified
  if (s.isDraw) return Outcome.draw;
  final isP1 = record.p1 == playerId;
  final p1Won = s.p1IsWinner;
  return (isP1 == p1Won) ? Outcome.win : Outcome.loss;
}

/// Aggregates statistics across many tournaments for durable identities.
class StatsEngine {
  final List<TournamentHistoryEntry> history;
  StatsEngine(this.history);

  /// Tournament list, newest first — backs the Events/history screen.
  List<TournamentHistoryEntry> get timeline =>
      [...history]..sort((a, b) => b.date.compareTo(a.date));

  /// Lifetime match record for a named deck across every tournament.
  Record deckRecord(String deckId) {
    final r = Record();
    for (final t in history) {
      for (final rec in t.records) {
        for (final pid in rec.isBye ? [rec.p1] : [rec.p1, rec.p2!]) {
          if (t.deckByPlayer[pid] == deckId) {
            r.add(outcomeFor(pid, rec));
          }
        }
      }
    }
    return r;
  }

  /// Head-to-head record of [deckId] versus [otherDeckId], from [deckId]'s side.
  Record deckHeadToHead(String deckId, String otherDeckId) {
    final r = Record();
    for (final t in history) {
      for (final rec in t.records) {
        if (rec.isBye) continue;
        final d1 = t.deckByPlayer[rec.p1];
        final d2 = t.deckByPlayer[rec.p2!];
        if (d1 == deckId && d2 == otherDeckId) {
          r.add(outcomeFor(rec.p1, rec));
        } else if (d2 == deckId && d1 == otherDeckId) {
          r.add(outcomeFor(rec.p2!, rec));
        }
      }
    }
    return r;
  }

  /// Lifetime stats for a durable player across all tournaments they entered.
  PlayerLifetime playerLifetime(String playerId) {
    final mr = Record();
    var gamePoints = 0;
    var games = 0;
    var played = 0;
    var won = 0;

    for (final t in history) {
      if (!t.deckByPlayer.containsKey(playerId)) continue;
      played++;
      for (final rec in t.records) {
        final involved = rec.isBye
            ? rec.p1 == playerId
            : (rec.p1 == playerId || rec.p2 == playerId);
        if (!involved) continue;
        mr.add(outcomeFor(playerId, rec));
        if (rec.isBye) {
          gamePoints += 6;
          games += 2;
        } else {
          final s = rec.score;
          final isP1 = rec.p1 == playerId;
          gamePoints += (isP1 ? s.p1Wins : s.p2Wins) * 3 + s.draws;
          games += s.totalGames;
        }
      }
      // tournament win = top of that event's standings
      final standings = computeStandings(t.records, t.players);
      if (standings.isNotEmpty && standings.first.playerId == playerId) won++;
    }

    return PlayerLifetime(
      playerId: playerId,
      tournamentsPlayed: played,
      tournamentsWon: won,
      matchRecord: mr,
      gameWinPct: games == 0 ? 0 : gamePoints / (3 * games),
    );
  }
}
