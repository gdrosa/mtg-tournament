import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/swiss.dart';
import 'package:mtg_tourney/shared/tournament_engine.dart';

import 'stats_fixture.dart';

DateTime _now = DateTime.utc(2026, 8, 6, 19);

TournamentEngine _engine({
  int players = 4,
  TournamentKind kind = TournamentKind.swiss,
  int seed = 3,
  int roundMinutes = 0,
  bool start = true,
}) {
  final e = TournamentEngine(
    id: 't1',
    name: 'Test Cup',
    createdAt: DateTime.utc(2026, 8, 6),
    kind: kind,
    roundMinutes: roundMinutes,
    rng: Random(seed),
    clock: () => _now,
  );
  for (var i = 1; i <= players; i++) {
    e.addEntry('P$i', 'deck$i');
  }
  if (start) e.start();
  return e;
}

/// Confirm every unresolved match in the round; [winner] picks the seat that
/// takes it, so a knockout's bracket is deterministic.
void _playRound(TournamentEngine e, {bool p1Wins = true, bool draw = false}) {
  for (final m in [...e.currentRound.matches]) {
    if (m.isBye || m.state == MatchState.confirmed) continue;
    final score = draw
        ? const GameScore(1, 1, 1)
        : (p1Wins ? const GameScore(2, 0) : const GameScore(0, 2));
    e.submitResult(m.id, m.p1Id, score);
    e.submitResult(m.id, m.p2Id!, score);
    e.confirmNoInfraction(m.id, m.p1Id, true);
    e.confirmNoInfraction(m.id, m.p2Id!, true);
  }
}

void main() {
  setUp(() => _now = DateTime.utc(2026, 8, 6, 19));

  group('recommended Swiss rounds', () {
    test('each tier is the rounds needed to leave one undefeated player', () {
      // The bug this replaces: 4 players were given 3 rounds, when a 2-0 record
      // has already decided it.
      expect(recommendedRounds(2), 1);
      expect(recommendedRounds(3), 2);
      expect(recommendedRounds(4), 2);
      expect(recommendedRounds(5), 3);
      expect(recommendedRounds(8), 3);
      expect(recommendedRounds(9), 4);
      expect(recommendedRounds(16), 4);
      expect(recommendedRounds(17), 5);
      expect(recommendedRounds(32), 5);
      expect(recommendedRounds(64), 6);
    });

    test('below two players there is nothing to play', () {
      expect(recommendedRounds(1), 0);
      expect(recommendedRounds(0), 0);
    });

    test('a 4-player event finishes after two rounds', () {
      final e = _engine();
      expect(e.plannedRounds, 2);
      _playRound(e);
      e.advanceRound();
      expect(e.status, TournamentStatus.running);
      _playRound(e);
      e.advanceRound();
      expect(e.status, TournamentStatus.finished);
      expect(e.rounds, hasLength(2));
    });
  });

  group('bracket rounds', () {
    test('halves the field until one is left', () {
      expect(bracketRounds(2), 1);
      expect(bracketRounds(4), 2);
      expect(bracketRounds(5), 3);
      expect(bracketRounds(8), 3);
      expect(bracketRounds(9), 4);
      expect(bracketRounds(1), 0);
    });
  });

  group('manual round count', () {
    test('an override set in the lobby survives the start', () {
      final e = _engine(start: false)..setPlannedRounds(5);
      e.start();
      expect(e.plannedRounds, 5);
    });

    test('the host can add a round mid-event', () {
      final e = _engine();
      _playRound(e);
      e.advanceRound();
      e.setPlannedRounds(4);
      _playRound(e);
      e.advanceRound();
      expect(e.status, TournamentStatus.running);
      expect(e.rounds, hasLength(3));
    });

    test('it can never fall below the rounds already paired', () {
      final e = _engine();
      _playRound(e);
      e.advanceRound(); // now two rounds exist
      expect(() => e.setPlannedRounds(1), throwsA(isA<EngineError>()));
      expect(e.plannedRounds, 2);
    });

    test('absurd counts are refused', () {
      final e = _engine(start: false);
      expect(() => e.setPlannedRounds(0), throwsA(isA<EngineError>()));
      expect(
        () => e.setPlannedRounds(kMaxPlannedRounds + 1),
        throwsA(isA<EngineError>()),
      );
    });

    test('shortening it ends the event at the next advance', () {
      final e = _engine(players: 8);
      expect(e.plannedRounds, 3);
      e.setPlannedRounds(1);
      _playRound(e);
      e.advanceRound();
      expect(e.status, TournamentStatus.finished);
    });

    test('a knockout refuses: its length is arithmetic', () {
      final e = _engine(kind: TournamentKind.singleElimination);
      expect(() => e.setPlannedRounds(5), throwsA(isA<EngineError>()));
    });

    test('a stale lobby override cannot truncate a bracket', () {
      final e = _engine(
        players: 8,
        kind: TournamentKind.singleElimination,
        start: false,
      )..plannedRounds = 1;
      e.start();
      expect(e.plannedRounds, 3);
    });
  });

  group('single elimination', () {
    test('only winners are paired in the next round', () {
      final e = _engine(players: 4, kind: TournamentKind.singleElimination);
      expect(e.plannedRounds, 2);
      final losers = [for (final m in e.currentRound.matches) m.p2Id!];
      _playRound(e);
      e.advanceRound();
      expect(e.currentRound.matches, hasLength(1));
      final seated = e.currentRound.matches.first.playerIds;
      for (final loser in losers) {
        expect(seated, isNot(contains(loser)));
      }
    });

    test('an odd field byes through and still crowns one winner', () {
      final e = _engine(players: 5, kind: TournamentKind.singleElimination);
      expect(e.plannedRounds, 3);
      var guard = 0;
      while (e.status == TournamentStatus.running && guard++ < 10) {
        _playRound(e);
        e.advanceRound();
      }
      expect(e.status, TournamentStatus.finished);
      // Exactly one player never lost.
      final standings = e.currentStandings();
      expect(
        standings.first.matchPoints,
        greaterThan(standings[1].matchPoints),
      );
    });

    test('a drawn match blocks the bracket instead of picking a winner', () {
      final e = _engine(players: 4, kind: TournamentKind.singleElimination);
      _playRound(e, draw: true);
      expect(e.isCurrentRoundComplete, isTrue);
      expect(() => e.advanceRound(), throwsA(isA<EngineError>()));
      // The organizer sets a real result, and the bracket moves on.
      final m = e.currentRound.matches.first;
      e.hostResolve(m.id, const GameScore(2, 1));
      final other = e.currentRound.matches[1];
      e.hostResolve(other.id, const GameScore(2, 1));
      e.advanceRound();
      expect(e.currentRound.number, 2);
    });

    test('a dropped winner does not stay in the bracket', () {
      final e = _engine(players: 4, kind: TournamentKind.singleElimination);
      _playRound(e);
      final winner = e.currentRound.matches.first.p1Id;
      e.dropPlayer(winner);
      e.advanceRound();
      // Only one survivor remains, so there is nothing left to play.
      expect(e.status, TournamentStatus.finished);
    });

    test('the kind survives a save/restore round trip', () {
      final e = _engine(players: 4, kind: TournamentKind.singleElimination);
      final back = TournamentEngine.fromJson(e.toJson());
      expect(back.kind, TournamentKind.singleElimination);
      expect(back.plannedRounds, 2);
    });

    test('an old save with no kind reads as Swiss', () {
      final json = _engine().toJson()..remove('kind');
      expect(TournamentEngine.fromJson(json).kind, TournamentKind.swiss);
    });
  });

  group('manual pairing edits', () {
    test('swapping two players re-seats both matches', () {
      final e = _engine(players: 4);
      final a = e.currentRound.matches[0];
      final b = e.currentRound.matches[1];
      final x = a.p1Id, y = b.p2Id!;
      e.swapPairing(x, y);
      expect(e.currentRound.matches[0].p1Id, y);
      expect(e.currentRound.matches[1].p2Id, x);
      // Ids are stable, so anything already referring to a match still works.
      expect(e.currentRound.matches[0].id, a.id);
    });

    test('the bye can be handed to someone else', () {
      final e = _engine(players: 5);
      final bye = e.currentRound.matches.firstWhere((m) => m.isBye);
      final byePlayer = bye.p1Id;
      final other = e.currentRound.matches.firstWhere((m) => !m.isBye).p1Id;
      e.swapPairing(byePlayer, other);
      final nowBye = e.currentRound.matches.firstWhere((m) => m.isBye);
      expect(nowBye.p1Id, other);
      // The moved bye is still an automatic, confirmed 2-0.
      expect(nowBye.state, MatchState.confirmed);
      expect(nowBye.accepted, const GameScore(2, 0));
    });

    test('a match with a reported result cannot be re-paired', () {
      final e = _engine(players: 4);
      final a = e.currentRound.matches[0];
      final b = e.currentRound.matches[1];
      e.submitResult(a.id, a.p1Id, const GameScore(2, 0));
      expect(() => e.swapPairing(a.p1Id, b.p1Id), throwsA(isA<EngineError>()));
      expect(e.currentRound.matches[0].p1Id, a.p1Id);
    });

    test('players already facing each other, or unknown, are refused', () {
      final e = _engine(players: 4);
      final a = e.currentRound.matches[0];
      expect(() => e.swapPairing(a.p1Id, a.p2Id!), throwsA(isA<EngineError>()));
      expect(() => e.swapPairing(a.p1Id, a.p1Id), throwsA(isA<EngineError>()));
      expect(() => e.swapPairing(a.p1Id, 'ghost'), throwsA(isA<EngineError>()));
    });

    test('a re-seated match plays out normally', () {
      final e = _engine(players: 4);
      final a = e.currentRound.matches[0];
      e.swapPairing(a.p1Id, e.currentRound.matches[1].p2Id!);
      _playRound(e);
      expect(e.isCurrentRoundComplete, isTrue);
    });
  });

  group('round timer', () {
    test('a configured length starts the clock with each round', () {
      final e = _engine(players: 4, roundMinutes: 50);
      expect(e.roundEndsAt, _now.add(const Duration(minutes: 50)));
      _now = _now.add(const Duration(minutes: 55));
      _playRound(e);
      e.advanceRound();
      expect(e.roundEndsAt, _now.add(const Duration(minutes: 50)));
    });

    test('no timer is configured by default', () {
      expect(_engine(players: 4).roundEndsAt, isNull);
    });

    test('the host can set, restart and stop it mid-round', () {
      final e = _engine(players: 4);
      e.setRoundMinutes(30);
      expect(e.roundEndsAt, _now.add(const Duration(minutes: 30)));
      _now = _now.add(const Duration(minutes: 10));
      e.startRoundTimer();
      expect(e.roundEndsAt, _now.add(const Duration(minutes: 30)));
      e.stopRoundTimer();
      expect(e.roundEndsAt, isNull);
      expect(
        e.roundMinutes,
        30,
        reason: 'stopping keeps the configured length',
      );
    });

    test('setting it to zero turns it off', () {
      final e = _engine(players: 4, roundMinutes: 30)..setRoundMinutes(0);
      expect(e.roundEndsAt, isNull);
      expect(() => e.startRoundTimer(), throwsA(isA<EngineError>()));
    });

    test('an absurd length is refused', () {
      final e = _engine(players: 4);
      expect(() => e.setRoundMinutes(-1), throwsA(isA<EngineError>()));
      expect(
        () => e.setRoundMinutes(kMaxRoundMinutes + 1),
        throwsA(isA<EngineError>()),
      );
    });

    test('running out of time changes nothing about the tournament', () {
      final e = _engine(players: 4, roundMinutes: 5);
      final before = e.currentRound.matches.map((m) => m.state).toList();
      _now = _now.add(const Duration(hours: 2));
      expect(e.status, TournamentStatus.running);
      expect(e.currentRound.matches.map((m) => m.state).toList(), before);
      expect(e.isCurrentRoundComplete, isFalse);
      // And the round still advances only once the host resolves it.
      expect(() => e.advanceRound(), throwsA(isA<EngineError>()));
    });

    test('the deadline survives a save/restore round trip', () {
      final e = _engine(players: 4, roundMinutes: 50);
      final back = TournamentEngine.fromJson(e.toJson());
      expect(back.roundMinutes, 50);
      expect(back.roundEndsAt, e.roundEndsAt);
    });
  });

  group('through the controller', () {
    ({
      TestClock clock,
      ServerController c,
      Persistence store,
      String host,
      String other,
    })
    started({int roundMinutes = 0}) {
      final clock = TestClock();
      final store = MemoryPersistence();
      final c = controllerWith(clock, store: store);
      final a = enrol(c, 'Ana', deckName: 'Zoo', main: '4 Ragavan');
      final b = enrol(c, 'Bo', deckName: 'Burn', main: '4 Goblin Guide');
      c.createTournament(
        name: 'Friday',
        hostPlayerId: a.playerId,
        roundMinutes: roundMinutes,
      );
      c.joinTournament(playerId: a.playerId, deckId: a.deckId);
      c.joinTournament(playerId: b.playerId, deckId: b.deckId);
      c.startTournament();
      return (
        clock: clock,
        c: c,
        store: store,
        host: a.playerId,
        other: b.playerId,
      );
    }

    test('the host snapshot carries the kind, timer and seat ids', () {
      final t = started(roundMinutes: 50);
      final snap = t.c.snapshotFor(t.host);
      expect(snap['kind'], 'swiss');
      expect(snap['roundMinutes'], 50);
      expect(
        DateTime.parse(snap['roundEndsAt'] as String),
        t.clock.now.add(const Duration(minutes: 50)),
      );
      final pairing = (snap['pairings'] as List).first as Map;
      expect([pairing['p1Id'], pairing['p2Id']], contains(t.host));
      expect(pairing['editable'], isTrue);
    });

    test('a player snapshot still has no pairing report at all', () {
      final t = started();
      final snap = t.c.snapshotFor(t.other);
      expect(snap['pairings'], isEmpty, reason: 'seat ids are host-only');
      expect(snap['roundEndsAt'], isNull, reason: 'no timer was configured');
      expect(snap['kind'], 'swiss', reason: 'the structure is public');
    });

    test('a match with a result is no longer marked editable', () {
      final t = started();
      final m = firstRealMatch(t.c);
      t.c.submitResult(playerId: t.host, matchId: m.id, mineWon: 2, oppWon: 0);
      final pairing =
          (t.c.snapshotFor(t.host)['pairings'] as List).first as Map;
      expect(pairing['editable'], isFalse);
    });

    test('host commands persist and reload', () {
      final t = started();
      t.c.setRoundMinutes(40);
      t.c.setPlannedRounds(4);
      final reloaded = controllerWith(t.clock, store: t.store)..loadFromStore();
      expect(reloaded.engine!.roundMinutes, 40);
      expect(reloaded.engine!.plannedRounds, 4);
      expect(reloaded.engine!.roundEndsAt, isNotNull);
    });
  });
}
