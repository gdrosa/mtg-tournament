import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/questionnaire.dart';
import 'package:mtg_tourney/shared/tournament_engine.dart';

import 'stats_fixture.dart';

/// The questionnaire is optional, private, time-boxed and inert: it must never
/// change a result, block a round, or show one player another's answers.
void main() {
  /// A running two-player event with round 1 confirmed 2-1.
  ({ServerController c, TestClock clock, String a, String b, String matchId})
  liveEvent({int aWins = 2, int bWins = 1}) {
    final clock = TestClock();
    final c = controllerWith(clock);
    final ana = enrol(c, 'Ana', deckName: 'Zoo');
    final bo = enrol(c, 'Bo', deckName: 'Burn');
    c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
    c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
    c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);
    c.startTournament();
    final m = firstRealMatch(c);
    final anaIsP1 = m.p1Id == ana.playerId;
    confirmMatch(c, m, anaIsP1 ? aWins : bWins, anaIsP1 ? bWins : aWins);
    return (c: c, clock: clock, a: ana.playerId, b: bo.playerId, matchId: m.id);
  }

  void answer(
    ServerController c,
    String playerId,
    String matchId, {
    required List<GameOutcome> games,
    List<MulliganCount>? mulligans,
    TriState play1 = TriState.unknown,
    TriState sideboarded = TriState.unknown,
  }) => c.submitSurvey(
    playerId: playerId,
    matchId: matchId,
    games: games,
    mulligans: mulligans ?? List.filled(games.length, MulliganCount.unknown),
    onThePlayGame1: play1,
    sideboarded: sideboarded,
  );

  group('prompt generation', () {
    test('asks about exactly the games that were played', () {
      final twoGames = SurveyPrompt.forMatch(
        Match(id: 'm', p1Id: 'a', p2Id: 'b', state: MatchState.confirmed)
          ..accepted = const GameScore(2, 0),
      )!;
      expect(twoGames.gameCount, 2);
      expect(twoGames.asksSideboard, isTrue);

      final threeGames = SurveyPrompt.forMatch(
        Match(id: 'm', p1Id: 'a', p2Id: 'b', state: MatchState.confirmed)
          ..accepted = const GameScore(2, 1),
      )!;
      expect(threeGames.gameCount, 3);
      // 3 results + 3 mulligans + play/draw + sideboard = eight taps.
      expect(threeGames.questionCount, 8);
    });

    test('a bye and an unconfirmed match are never asked about', () {
      final bye = Match(id: 'm', p1Id: 'a', state: MatchState.confirmed)
        ..accepted = const GameScore(2, 0);
      expect(SurveyPrompt.forMatch(bye), isNull);

      final pending = Match(id: 'm', p1Id: 'a', p2Id: 'b');
      expect(SurveyPrompt.forMatch(pending), isNull);
    });
  });

  group('lifecycle', () {
    test('opens automatically when a match is confirmed', () {
      final e = liveEvent();
      final survey = e.c.surveyFor(e.a);
      expect(survey, isNotNull);
      expect(survey!.gameCount, 3);
      expect(survey.isOpen(e.clock.now), isTrue);
      expect(survey.hasAnswered(e.a), isFalse);
    });

    test('expires on its own, and a late answer is refused', () {
      final e = liveEvent();
      e.clock.advance(surveyWindow + const Duration(minutes: 1));
      expect(e.c.surveyFor(e.a)!.isOpen(e.clock.now), isFalse);
      expect(
        () => answer(
          e.c,
          e.a,
          e.matchId,
          games: const [GameOutcome.win, GameOutcome.loss, GameOutcome.win],
        ),
        throwsA(isA<EngineError>()),
      );
    });

    test('advancing the round closes it and never waits for it', () {
      final e = liveEvent();
      // Nobody answered; the round must still advance.
      expect(e.c.engine!.isCurrentRoundComplete, isTrue);
      e.c.advanceRound();
      expect(e.c.surveys.values.single.closed, isTrue);
      expect(
        () => answer(
          e.c,
          e.a,
          e.matchId,
          games: const [GameOutcome.win, GameOutcome.loss, GameOutcome.win],
        ),
        throwsA(isA<EngineError>()),
      );
    });

    test('answering changes nothing about the match', () {
      final e = liveEvent();
      final before = e.c.engine!.currentRound.matches.firstWhere(
        (m) => m.id == e.matchId,
      );
      final resultBefore = before.accepted;
      final stateBefore = before.state;

      // Deliberately contradict the confirmed result.
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.loss, GameOutcome.loss, GameOutcome.loss],
      );

      final after = e.c.engine!.currentRound.matches.firstWhere(
        (m) => m.id == e.matchId,
      );
      expect(after.accepted, resultBefore);
      expect(after.state, stateBefore);
    });

    test('a blank submission is recorded as an explicit skip', () {
      final e = liveEvent();
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [
          GameOutcome.unknown,
          GameOutcome.unknown,
          GameOutcome.unknown,
        ],
      );
      final survey = e.c.surveyFor(e.a)!;
      expect(survey.responses[e.a]!.isBlank, isTrue);
      expect(survey.hasAnswered(e.b), isFalse);
    });
  });

  group('validation', () {
    test('the answer must cover every game played', () {
      final e = liveEvent();
      expect(
        () => answer(
          e.c,
          e.a,
          e.matchId,
          games: const [GameOutcome.win], // match went three games
        ),
        throwsA(isA<EngineError>()),
      );
    });

    test('someone who did not play the match cannot answer it', () {
      final e = liveEvent();
      final survey = e.c.surveyFor(e.a)!;
      expect(
        () => survey.submit(
          SurveyResponse(
            playerId: 'stranger',
            submittedAt: e.clock.now,
            games: const [GameOutcome.win, GameOutcome.win, GameOutcome.win],
            mulligans: const [
              MulliganCount.zero,
              MulliganCount.zero,
              MulliganCount.zero,
            ],
          ),
          e.clock.now,
        ),
        throwsA(isA<SurveyError>()),
      );
    });

    test('an unknown match id is refused', () {
      final e = liveEvent();
      expect(
        () => answer(e.c, e.a, 'no-such-match', games: const [GameOutcome.win]),
        throwsA(isA<EngineError>()),
      );
    });
  });

  group('cross-checks preserve conflicts', () {
    test('incompatible game results are both kept and reported', () {
      final e = liveEvent();
      // Both claim to have won game 1.
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.loss, GameOutcome.win],
      );
      answer(
        e.c,
        e.b,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.win, GameOutcome.loss],
      );
      final survey = e.c.surveyFor(e.a)!;
      final kinds = survey.conflicts.map((x) => x.kind).toSet();
      expect(kinds, contains(ConflictKind.gameResult));
      // Nothing was overwritten.
      expect(survey.responses[e.a]!.games.first, GameOutcome.win);
      expect(survey.responses[e.b]!.games.first, GameOutcome.win);
    });

    test('both players claiming the play in game 1 is a conflict', () {
      final e = liveEvent();
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.loss, GameOutcome.win],
        play1: TriState.yes,
      );
      answer(
        e.c,
        e.b,
        e.matchId,
        games: const [GameOutcome.loss, GameOutcome.win, GameOutcome.loss],
        play1: TriState.yes,
      );
      expect(
        e.c.surveyFor(e.a)!.conflicts.map((x) => x.kind),
        contains(ConflictKind.playDraw),
      );
    });

    test('a tally that contradicts the confirmed result is flagged', () {
      final e = liveEvent();
      final anaWon = e.c.engine!.currentRound.matches.firstWhere(
        (m) => m.id == e.matchId,
      );
      // Ana actually went 2-1; claim 3-0.
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.win, GameOutcome.win],
      );
      expect(anaWon.accepted, isNotNull);
      expect(
        e.c.surveyFor(e.a)!.conflicts.map((x) => x.kind),
        contains(ConflictKind.resultTally),
      );
    });

    test('compatible answers produce no conflicts', () {
      final e = liveEvent();
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.loss, GameOutcome.win],
        play1: TriState.yes,
      );
      answer(
        e.c,
        e.b,
        e.matchId,
        games: const [GameOutcome.loss, GameOutcome.win, GameOutcome.loss],
        play1: TriState.no,
      );
      expect(e.c.surveyFor(e.a)!.conflicts, isEmpty);
    });

    test('the host can list conflicts for an event', () {
      final e = liveEvent();
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.win, GameOutcome.win],
      );
      final found = e.c.surveyConflicts(e.c.engine!.id);
      expect(found, hasLength(1));
      expect(found.single.matchId, e.matchId);
    });
  });

  group('privacy', () {
    test(
      'a player snapshot carries own answers only, never the opponent\'s',
      () {
        final e = liveEvent();
        answer(
          e.c,
          e.b,
          e.matchId,
          games: const [GameOutcome.loss, GameOutcome.win, GameOutcome.loss],
          mulligans: const [
            MulliganCount.one,
            MulliganCount.zero,
            MulliganCount.threePlus,
          ],
        );

        final anaView = e.c.snapshotFor(e.a);
        final survey = (anaView['yourMatch'] as Map)['survey'] as Map;
        expect(survey['opponentAnswered'], isTrue);
        expect(survey['answered'], isFalse);
        expect(survey['yours'], isNull);
        expect(
          survey.toString(),
          isNot(contains('threePlus')),
          reason: "Bo's mulligans must not reach Ana's snapshot",
        );

        final boView = e.c.snapshotFor(e.b);
        final boSurvey = (boView['yourMatch'] as Map)['survey'] as Map;
        expect(boSurvey['answered'], isTrue);
        expect(boSurvey['yours'], isNotNull);
      },
    );

    test('conflicts are never exposed to players', () {
      final e = liveEvent();
      answer(
        e.c,
        e.a,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.win, GameOutcome.win],
      );
      answer(
        e.c,
        e.b,
        e.matchId,
        games: const [GameOutcome.win, GameOutcome.win, GameOutcome.win],
      );
      expect(e.c.surveyFor(e.a)!.conflicts, isNotEmpty);
      for (final viewer in [e.a, e.b]) {
        final survey =
            (e.c.snapshotFor(viewer)['yourMatch'] as Map)['survey'] as Map;
        expect(survey.containsKey('conflicts'), isFalse);
      }
    });

    test('answers are marked self-reported and survive a reload', () {
      final clock = TestClock();
      final store = MemoryPersistence();
      final c = controllerWith(clock, store: store);
      final ana = enrol(c, 'Ana', deckName: 'Zoo');
      final bo = enrol(c, 'Bo', deckName: 'Burn');
      c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
      c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
      c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);
      c.startTournament();
      final m = firstRealMatch(c);
      confirmMatch(c, m, 2, 0);
      c.submitSurvey(
        playerId: ana.playerId,
        matchId: m.id,
        games: const [GameOutcome.win, GameOutcome.win],
        mulligans: const [MulliganCount.zero, MulliganCount.one],
        sideboarded: TriState.yes,
      );

      final restored = controllerWith(clock, store: store)..loadFromStore();
      final survey = restored.surveys.values.single;
      final response = survey.responses[ana.playerId]!;
      expect(response.selfReported, isTrue);
      expect(response.mulligans[1], MulliganCount.one);
      expect(response.sideboarded, TriState.yes);
      expect(response.toJson()['selfReported'], isTrue);
    });
  });
}
