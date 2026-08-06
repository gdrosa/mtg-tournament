import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/shared/models.dart';
import 'package:mtg_tourney/shared/swiss.dart';
import 'package:mtg_tourney/shared/tournament_engine.dart';

TournamentEngine _engine({int players = 4, int seed = 1}) {
  final e = TournamentEngine(
    id: 't1',
    name: 'Test Cup',
    createdAt: DateTime(2026, 6, 14),
    rng: Random(seed),
  );
  for (var i = 1; i <= players; i++) {
    e.addEntry('P$i', 'deck$i');
  }
  e.start();
  return e;
}

/// Submit a p1 2-0 win and both thumbs-up for every non-bye match in the round.
void _confirmEntireRound(TournamentEngine e) {
  for (final m in e.currentRound.matches) {
    if (m.isBye) continue;
    e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
    e.submitResult(m.id, m.p2Id!, const GameScore(2, 0));
    e.confirmNoInfraction(m.id, m.p1Id, true);
    e.confirmNoInfraction(m.id, m.p2Id!, true);
  }
}

void main() {
  group('setup', () {
    test('start pairs 4 players into 2 matches and plans 2 rounds', () {
      final e = _engine();
      expect(e.status, TournamentStatus.running);
      expect(e.currentRound.matches.where((m) => !m.isBye).length, 2);
      // Two rounds leave exactly one 2-0 player; a third would be padding.
      expect(e.plannedRounds, 2);
    });

    test('cannot join after start', () {
      final e = _engine();
      expect(() => e.addEntry('late', 'd'), throwsA(isA<EngineError>()));
    });
  });

  group('dual-confirmation', () {
    test('matching submissions are accepted; both thumbs-up confirms', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      expect(m.state, MatchState.awaitingSecond);
      e.submitResult(m.id, m.p2Id!, const GameScore(2, 0));
      expect(m.state, MatchState.resultAccepted);
      expect(m.accepted, const GameScore(2, 0));
      e.confirmNoInfraction(m.id, m.p1Id, true);
      expect(m.state, MatchState.resultAccepted); // still waiting on p2
      e.confirmNoInfraction(m.id, m.p2Id!, true);
      expect(m.state, MatchState.confirmed);
    });

    test('a single session cannot satisfy both sides', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0)); // same player again
      expect(m.state, MatchState.awaitingSecond);
      expect(m.accepted, isNull);
    });

    test('mismatched submissions escalate to host review', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      e.submitResult(m.id, m.p2Id!, const GameScore(0, 2));
      expect(m.state, MatchState.needsReview);
      expect(m.reviewReason, ReviewReason.resultMismatch);
      expect(m.accepted, isNull);
      // Host adjudicates.
      e.hostResolve(m.id, const GameScore(2, 1), note: 'checked with both');
      expect(m.state, MatchState.confirmed);
      expect(m.accepted, const GameScore(2, 1));
    });

    test('a reported infraction (thumbs-down) escalates to host review', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      e.submitResult(m.id, m.p2Id!, const GameScore(2, 0));
      e.confirmNoInfraction(m.id, m.p1Id, true);
      e.confirmNoInfraction(m.id, m.p2Id!, false); // infraction!
      expect(m.state, MatchState.needsReview);
      expect(m.reviewReason, ReviewReason.infractionReported);

      // A stale score form must not erase the infraction alert. An identical
      // retry is harmless; an amendment now requires host adjudication.
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      expect(m.state, MatchState.needsReview);
      expect(m.reviewReason, ReviewReason.infractionReported);
      expect(
        () => e.submitResult(m.id, m.p1Id, const GameScore(2, 1)),
        throwsA(isA<EngineError>()),
      );
      expect(m.reviewReason, ReviewReason.infractionReported);
    });

    test('a player may amend before reconciliation; re-send is idempotent', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
      e.submitResult(m.id, m.p1Id, const GameScore(2, 1)); // amend
      e.submitResult(m.id, m.p2Id!, const GameScore(2, 1));
      expect(m.accepted, const GameScore(2, 1));
      // idempotent re-send after acceptance: no throw, no change
      e.submitResult(m.id, m.p1Id, const GameScore(2, 1));
      expect(m.state, MatchState.resultAccepted);
    });
  });

  group('round gating & progression', () {
    test('cannot advance until every match is confirmed', () {
      final e = _engine();
      expect(e.isCurrentRoundComplete, isFalse);
      expect(() => e.advanceRound(), throwsA(isA<EngineError>()));
      _confirmEntireRound(e);
      expect(e.isCurrentRoundComplete, isTrue);
      e.advanceRound();
      expect(e.currentRound.number, 2);
    });

    test('a full run finishes with no rematches', () {
      final e = _engine();
      final allPairs = <String>{};
      while (e.status == TournamentStatus.running) {
        for (final m in e.currentRound.matches) {
          if (!m.isBye) {
            final k = pairKey(m.p1Id, m.p2Id!);
            expect(allPairs.contains(k), isFalse, reason: 'rematch $k');
            allPairs.add(k);
          }
        }
        _confirmEntireRound(e);
        e.advanceRound();
      }
      expect(e.status, TournamentStatus.finished);
      expect(e.rounds.length, 2); // 4 players decide it in 2 rounds
      expect(e.currentStandings().length, 4);
    });
  });

  group('byes & drops', () {
    test('odd field auto-confirms a bye that does not block the round', () {
      final e = _engine(players: 3);
      final byes = e.currentRound.matches.where((m) => m.isBye).toList();
      expect(byes.length, 1);
      expect(byes.first.state, MatchState.confirmed);
      _confirmEntireRound(e); // confirms the single real match
      expect(e.isCurrentRoundComplete, isTrue);
    });

    test('dropping a player mid-round awards the opponent the match', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      final loser = m.p1Id;
      final winner = m.p2Id!;
      e.dropPlayer(loser);
      expect(m.state, MatchState.confirmed);
      // opponent credited a 2-0 in canonical orientation
      final expected = winner == m.p1Id
          ? const GameScore(2, 0)
          : const GameScore(0, 2);
      expect(m.accepted, expected);
      expect(e.activePlayerIds.contains(loser), isFalse);
    });
  });

  group('regressions (bug-hunt batch)', () {
    test(
      'drop after an agreed result keeps the score and a late thumbs-up cannot un-confirm it',
      () {
        final e = _engine();
        final m = e.currentRound.matches.first;
        // Both agree 2-1 → resultAccepted (awaiting the post-match infraction thumbs).
        e.submitResult(m.id, m.p1Id, const GameScore(2, 1));
        e.submitResult(m.id, m.p2Id!, const GameScore(2, 1));
        expect(m.state, MatchState.resultAccepted);
        // p1 drops: the agreed 2-1 must be preserved (not clobbered to 2-0) and the
        // match confirmed so the round can still complete.
        e.dropPlayer(m.p1Id);
        expect(m.state, MatchState.confirmed);
        expect(m.accepted, const GameScore(2, 1));
        // A late/duplicate thumbs-up from the still-active player is a no-op — it must
        // NOT downgrade the confirmed match (which would deadlock the round forever).
        e.confirmNoInfraction(m.id, m.p2Id!, true);
        expect(m.state, MatchState.confirmed);
        expect(m.accepted, const GameScore(2, 1));
      },
    );

    test(
      'a late thumbs-up after host resolution does not un-confirm the match',
      () {
        final e = _engine();
        final m = e.currentRound.matches.first;
        e.submitResult(m.id, m.p1Id, const GameScore(2, 0));
        e.submitResult(
          m.id,
          m.p2Id!,
          const GameScore(0, 2),
        ); // mismatch → needsReview
        e.hostResolve(m.id, const GameScore(2, 1));
        expect(m.state, MatchState.confirmed);
        e.confirmNoInfraction(
          m.id,
          m.p1Id,
          true,
        ); // in-flight thumbs-up arrives late
        expect(m.state, MatchState.confirmed);
        expect(m.accepted, const GameScore(2, 1));
      },
    );

    test('illegal best-of-3 scores are rejected (submit and host-resolve)', () {
      final e = _engine();
      final m = e.currentRound.matches.first;
      expect(
        () => e.submitResult(m.id, m.p1Id, const GameScore(9, 0)),
        throwsA(isA<EngineError>()),
      );
      expect(
        () => e.submitResult(m.id, m.p1Id, const GameScore(-1, 0)),
        throwsA(isA<EngineError>()),
      );
      expect(
        () => e.hostResolve(m.id, const GameScore(20, 0)),
        throwsA(isA<EngineError>()),
      );
      // a legal line is still accepted
      e.submitResult(m.id, m.p1Id, const GameScore(2, 1));
      expect(m.state, MatchState.awaitingSecond);
    });
  });
}
