import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';

/// Tests for tournament archiving + the history/statistics read model that
/// backs the Events / Decks / Profile screens. Pure Dart, headless on Windows.
void main() {
  // Drive a 2-player event to a confirmed round, then close it.
  ServerController playOneEvent(ServerController c, {required String name}) {
    final host = c.ensureOwner('Host');
    c.createTournament(name: name, hostPlayerId: host.playerId);
    final hostDeck = c.saveDeck(
      ownerId: host.playerId,
      name: 'Domain Zoo',
      mainboard: '',
      sideboard: '',
    );
    c.joinTournament(playerId: host.playerId, deckId: hostDeck.id);
    final alice = c.resolveSession('Alice', null);
    final aliceDeck = c.saveDeck(
      ownerId: alice.playerId,
      name: 'Mono-Red',
      mainboard: '',
      sideboard: '',
    );
    c.joinTournament(playerId: alice.playerId, deckId: aliceDeck.id);

    c.startTournament();
    final m = c.engine!.currentRound.matches.firstWhere((x) => !x.isBye);
    c.submitResult(
      playerId: host.playerId,
      matchId: m.id,
      mineWon: 2,
      oppWon: 1,
    );
    c.submitResult(
      playerId: alice.playerId,
      matchId: m.id,
      mineWon: 1,
      oppWon: 2,
    );
    c.confirmInfraction(playerId: host.playerId, matchId: m.id, ok: true);
    c.confirmInfraction(playerId: alice.playerId, matchId: m.id, ok: true);
    return c;
  }

  test(
    'a played event is archived on close; a never-started lobby is discarded',
    () {
      final c = ServerController(rng: Random(1));
      playOneEvent(c, name: 'Friday Modern');
      expect(c.archive, isEmpty); // not archived until the event is closed
      c.clearTournament();
      expect(c.engine, isNull);
      expect(c.archive, hasLength(1));
      expect(c.ownerPlayerId, isNotNull); // owner identity survives the event

      // a lobby that never started leaves no trace
      final host = c.ensureOwner('Host');
      c.createTournament(name: 'Empty', hostPlayerId: host.playerId);
      c.clearTournament();
      expect(c.archive, hasLength(1));
    },
  );

  test(
    'history feeds the stats engine: deck record + lifetime + tournament win',
    () {
      final c = ServerController(rng: Random(2));
      playOneEvent(c, name: 'Friday Modern');
      final ownerId = c.ownerPlayerId!;
      final hostDeck = c.decksOf(ownerId).single;
      c.clearTournament();

      final stats = c.stats;
      final zoo = stats.deckRecord(hostDeck.id);
      expect([zoo.wins, zoo.losses], [1, 0]);

      final life = stats.playerLifetime(ownerId);
      expect(life.tournamentsPlayed, 1);
      expect(life.tournamentsWon, 1); // host won the only match
      expect([life.matchRecord.wins, life.matchRecord.losses], [1, 0]);
    },
  );

  test('deleteArchived removes a tournament from history', () {
    final c = ServerController(rng: Random(3));
    playOneEvent(c, name: 'Friday Modern');
    c.clearTournament();
    final id = c.archive.single.id;
    expect(c.tournamentById(id), isNotNull);
    c.deleteArchived(id);
    expect(c.archive, isEmpty);
    expect(c.tournamentById(id), isNull);
  });

  test('archive + owner identity round-trip through persistence', () {
    final store = MemoryPersistence();
    final c = ServerController(rng: Random(4))..store = store;
    playOneEvent(c, name: 'Friday Modern');
    c.clearTournament(); // persists (archive + owner)

    final restored = ServerController(rng: Random(4))..store = store;
    restored.loadFromStore();
    expect(restored.archive, hasLength(1));
    expect(restored.archive.single.name, 'Friday Modern');
    expect(restored.ownerPlayerId, c.ownerPlayerId);
    expect(restored.ownerToken, c.ownerToken);
    // history still computes after a reload
    expect(
      restored.stats.playerLifetime(restored.ownerPlayerId!).tournamentsPlayed,
      1,
    );
  });
}
