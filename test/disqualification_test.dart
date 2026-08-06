import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/swiss.dart';
import 'package:mtg_tourney/shared/tournament_engine.dart';

import 'stats_fixture.dart';

TournamentEngine _engine({int players = 4, int seed = 5}) {
  final e = TournamentEngine(
    id: 't1',
    name: 'Test Cup',
    createdAt: DateTime.utc(2026, 8, 6),
    rng: Random(seed),
  );
  for (var i = 1; i <= players; i++) {
    e.addEntry('P$i', 'deck$i');
  }
  e.start();
  return e;
}

/// Take a match all the way to the decklist check: both players report the same
/// score, so the lists are revealed and each side owes a confirmation.
Match _revealed(TournamentEngine e, {int index = 0}) {
  final m = e.currentRound.matches.where((x) => !x.isBye).elementAt(index);
  e.submitResult(m.id, m.p1Id, const GameScore(2, 1));
  e.submitResult(m.id, m.p2Id!, const GameScore(2, 1));
  return m;
}

void main() {
  group('the decklist check', () {
    test('a flagged decklist sends the match to the organizer', () {
      final e = _engine();
      final m = _revealed(e);
      e.confirmNoInfraction(m.id, m.p1Id, true);
      e.confirmNoInfraction(m.id, m.p2Id!, false);
      expect(m.state, MatchState.needsReview);
      expect(m.reviewReason, ReviewReason.infractionReported);
      expect(e.isCurrentRoundComplete, isFalse, reason: 'the round waits');
    });

    test('several flagged matches all wait for the organizer', () {
      final e = _engine(players: 8);
      for (var i = 0; i < 3; i++) {
        final m = _revealed(e, index: i);
        e.confirmNoInfraction(m.id, m.p1Id, false);
      }
      final queued = e.currentRound.matches
          .where((m) => m.state == MatchState.needsReview)
          .length;
      expect(
        queued,
        3,
        reason: 'every one of them is queued, not just the last',
      );
    });

    test('letting it stand confirms the match and keeps the result', () {
      final e = _engine();
      final m = _revealed(e);
      e.confirmNoInfraction(m.id, m.p1Id, false);
      e.hostResolve(m.id, const GameScore(2, 1));
      expect(m.state, MatchState.confirmed);
      expect(m.accepted, const GameScore(2, 1));
      expect(
        m.disputed,
        isTrue,
        reason: 'it was escalated, and stays recorded',
      );
    });
  });

  group('disqualification', () {
    test('one player: they are out and the opponent takes the win', () {
      final e = _engine();
      final m = _revealed(e);
      e.confirmNoInfraction(m.id, m.p2Id!, false);
      e.disqualify(m.id, [m.p1Id], note: 'Illegal decklist');

      expect(m.accepted, const GameScore(0, 2));
      expect(m.state, MatchState.confirmed);
      expect(m.adjudicated, isTrue);
      final entry = e.entryOf(m.p1Id)!;
      expect(entry.disqualified, isTrue);
      expect(entry.dropped, isTrue, reason: 'a DQ is also out of the event');
      expect(e.entryOf(m.p2Id!)!.disqualified, isFalse);
    });

    test('a disqualified player is not paired again', () {
      final e = _engine();
      final m = _revealed(e);
      e.disqualify(m.id, [m.p1Id]);
      // Finish the rest of the round.
      for (final x in e.currentRound.matches) {
        if (x.isBye || x.state == MatchState.confirmed) continue;
        e.submitResult(x.id, x.p1Id, const GameScore(2, 0));
        e.submitResult(x.id, x.p2Id!, const GameScore(2, 0));
        e.confirmNoInfraction(x.id, x.p1Id, true);
        e.confirmNoInfraction(x.id, x.p2Id!, true);
      }
      e.advanceRound();
      for (final x in e.currentRound.matches) {
        expect(x.playerIds, isNot(contains(m.p1Id)));
      }
    });

    test('both players: a double loss, not a 0-0 draw', () {
      final e = _engine();
      final m = _revealed(e);
      e.disqualify(m.id, [m.p1Id, m.p2Id!]);

      expect(m.accepted, const GameScore(0, 0));
      expect(m.accepted!.isDoubleLoss, isTrue);
      expect(m.accepted!.isDraw, isFalse);
      expect(m.state, MatchState.confirmed);

      final standings = computeStandings(e.matchRecords, [m.p1Id, m.p2Id!]);
      for (final row in standings) {
        expect(row.matchPoints, 0, reason: 'a double loss scores nothing');
        expect(row.roundsPlayed, 1, reason: 'the round still happened');
      }
    });

    test('a double loss reads as a loss for both, everywhere', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final a = enrol(c, 'Ana', deckName: 'Zoo', main: '4 Ragavan');
      final b = enrol(c, 'Bo', deckName: 'Burn', main: '4 Goblin Guide');
      c.createTournament(name: 'Friday', hostPlayerId: a.playerId);
      c.joinTournament(playerId: a.playerId, deckId: a.deckId);
      c.joinTournament(playerId: b.playerId, deckId: b.deckId);
      c.startTournament();
      final m = firstRealMatch(c);
      c.disqualify(m.id, [m.p1Id, m.p2Id!]);

      final facts = c.matchFacts();
      expect(facts, hasLength(1));
      expect(facts.single.outcomeFor(a.playerId).name, 'loss');
      expect(facts.single.outcomeFor(b.playerId).name, 'loss');
      // And no questionnaire: there were no games to ask about.
      expect(c.surveyFor(a.playerId), isNull);
    });

    test(
      'the round can be completed and advanced after a disqualification',
      () {
        final e = _engine(players: 4);
        final m = _revealed(e);
        e.confirmNoInfraction(m.id, m.p1Id, false);
        e.disqualify(m.id, [m.p2Id!]);
        final other = e.currentRound.matches.firstWhere(
          (x) => x.id != m.id && !x.isBye,
        );
        e.submitResult(other.id, other.p1Id, const GameScore(2, 0));
        e.submitResult(other.id, other.p2Id!, const GameScore(2, 0));
        e.confirmNoInfraction(other.id, other.p1Id, true);
        e.confirmNoInfraction(other.id, other.p2Id!, true);
        expect(e.isCurrentRoundComplete, isTrue);
        e.advanceRound();
        expect(e.currentRound.number, 2);
      },
    );

    test('nobody outside the match can be disqualified through it', () {
      final e = _engine();
      final m = _revealed(e);
      expect(() => e.disqualify(m.id, ['P9']), throwsA(isA<EngineError>()));
      expect(() => e.disqualify(m.id, const []), throwsA(isA<EngineError>()));
    });

    test('a bye has nobody to disqualify', () {
      final e = _engine(players: 3);
      final bye = e.currentRound.matches.firstWhere((m) => m.isBye);
      expect(
        () => e.disqualify(bye.id, [bye.p1Id]),
        throwsA(isA<EngineError>()),
      );
    });

    test('players still cannot submit a 0-0 themselves', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      expect(
        () => e.submitResult(m.id, m.p1Id, const GameScore(0, 0)),
        throwsA(isA<EngineError>()),
      );
      expect(
        () => e.hostResolve(m.id, const GameScore(0, 0)),
        throwsA(isA<EngineError>()),
      );
    });

    test('it survives a save/restore round trip', () {
      final e = _engine();
      final m = _revealed(e);
      e.disqualify(m.id, [m.p1Id], note: 'Illegal decklist');
      final back = TournamentEngine.fromJson(e.toJson());
      expect(back.entryOf(m.p1Id)!.disqualified, isTrue);
      expect(back.entryOf(m.p1Id)!.dropped, isTrue);
      expect(back.matchRecords.first.score.isDoubleLoss, isFalse);
    });

    test('a single elimination bracket advances nobody from a double DQ', () {
      final e = TournamentEngine(
        id: 't2',
        name: 'Bracket',
        createdAt: DateTime.utc(2026, 8, 6),
        kind: TournamentKind.singleElimination,
        rng: Random(5),
      );
      for (var i = 1; i <= 4; i++) {
        e.addEntry('P$i', 'deck$i');
      }
      e.start();
      final a = e.currentRound.matches[0];
      final b = e.currentRound.matches[1];
      e.disqualify(a.id, [a.p1Id, a.p2Id!]);
      e.submitResult(b.id, b.p1Id, const GameScore(2, 0));
      e.submitResult(b.id, b.p2Id!, const GameScore(2, 0));
      e.confirmNoInfraction(b.id, b.p1Id, true);
      e.confirmNoInfraction(b.id, b.p2Id!, true);
      e.advanceRound();
      // One survivor, so the bracket is over rather than pairing a ghost.
      expect(e.status, TournamentStatus.finished);
    });
  });

  group('standings expose the whole tiebreaker chain', () {
    test('every row carries OMW, GW and OGW', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runLeagueEvent(
        c,
        name: 'Friday',
        nicknames: ['Ana', 'Bo', 'Cy'],
        archive: false,
      );
      final rows = (c.snapshotFor(ids.players['Ana'])['standings'] as List)
          .cast<Map>();
      expect(rows, isNotEmpty);
      for (final r in rows) {
        for (final key in ['omw', 'gw', 'ogw']) {
          expect(r[key], isA<String>(), reason: '$key must reach the UI');
          expect(double.tryParse(r[key] as String), isNotNull);
        }
      }
    });
  });
}
