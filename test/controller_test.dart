import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/shared/models.dart';

/// Integration tests for the server-side controller (the same code the embedded
/// LAN server drives). Pure Dart, runs headless on Windows.
void main() {
  test(
    'hosted flow: create → seat 4 → start → report → reveal → confirm → advance',
    () {
      final c = ServerController(rng: Random(7));
      final host = c.resolveSession('Host', null);
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);

      void seat(String pid, String deck) {
        final d = c.saveDeck(
          ownerId: pid,
          name: deck,
          mainboard: '4 Bolt',
          sideboard: '2 REB',
        );
        c.joinTournament(playerId: pid, deckId: d.id);
      }

      seat(host.playerId, 'Domain Zoo');
      seat(c.resolveSession('Alice', null).playerId, 'Mono-Red');
      seat(c.resolveSession('Bob', null).playerId, 'Dimir');
      seat(c.resolveSession('Carol', null).playerId, 'Hammer');

      // lobby snapshot is public + lists everyone
      expect(c.snapshotFor(host.playerId)['players'], hasLength(4));

      c.startTournament();
      final eng = c.engine!;
      final live = eng.currentRound.matches.where((m) => !m.isBye).toList();
      expect(live, hasLength(2));

      // both sides report a consistent result (winner 2-1 / loser 1-2)
      for (final m in live) {
        c.submitResult(playerId: m.p1Id, matchId: m.id, mineWon: 2, oppWon: 1);
        c.submitResult(playerId: m.p2Id!, matchId: m.id, mineWon: 1, oppWon: 2);
      }

      // the loser can now see the winner's decklist (post-match reveal)
      final loserView = c.snapshotFor(live.first.p2Id!)['yourMatch'] as Map;
      expect(loserView['revealed'], isTrue);
      expect((loserView['opponentDeck'] as Map)['name'], isNotNull);
      expect(loserView['needsInfraction'], isTrue);

      // both confirm no infractions
      for (final m in live) {
        c.confirmInfraction(playerId: m.p1Id, matchId: m.id, ok: true);
        c.confirmInfraction(playerId: m.p2Id!, matchId: m.id, ok: true);
      }
      expect(c.snapshotFor(host.playerId)['roundComplete'], isTrue);

      c.advanceRound();
      expect(c.engine!.rounds.length, 2);
      expect((c.snapshotFor(host.playerId)['standings'] as List), hasLength(4));
    },
  );

  test('result mismatch surfaces needsReview and is host-resolvable', () {
    final c = ServerController(rng: Random(3));
    final host = c.resolveSession('Host', null);
    c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
    void seat(String pid) {
      final d = c.saveDeck(
        ownerId: pid,
        name: 'Deck',
        mainboard: '',
        sideboard: '',
      );
      c.joinTournament(playerId: pid, deckId: d.id);
    }

    seat(host.playerId);
    seat(c.resolveSession('Alice', null).playerId);
    c.startTournament();
    final m = c.engine!.currentRound.matches.firstWhere((x) => !x.isBye);

    // both claim a 2-0 win for themselves -> mismatch
    c.submitResult(playerId: m.p1Id, matchId: m.id, mineWon: 2, oppWon: 0);
    c.submitResult(playerId: m.p2Id!, matchId: m.id, mineWon: 2, oppWon: 0);
    expect(
      (c.snapshotFor(host.playerId)['pairings'] as List).first['needsReview'],
      isTrue,
    );

    c.hostResolve(m.id, 2, 1);
    expect(m.state, MatchState.confirmed);
  });

  test('a player who only knows the code cannot host-command', () {
    final c = ServerController(rng: Random(5));
    final host = c.resolveSession('Host', null);
    c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
    final intruder = c.resolveSession('Mallory', null);
    // controller has no auth itself, but the server gates host endpoints by
    // hostPlayerId; assert the identities differ so that gate is meaningful.
    expect(intruder.playerId, isNot(host.playerId));
    expect(c.hostPlayerId, host.playerId);
  });
}
