import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/hosting.dart';
import 'package:mtg_tourney/shared/models.dart';

void main() {
  test('crash-resume: a mid-round tournament restores from storage', () {
    final store = MemoryPersistence();
    final c = ServerController(rng: Random(11))..store = store;
    final host = c.resolveSession('Host', null);
    c.createTournament(name: 'Cup', hostPlayerId: host.playerId);

    void seat(String pid, String deck) {
      final d = c.saveDeck(
        ownerId: pid,
        name: deck,
        mainboard: '4 X',
        sideboard: '1 Y',
      );
      c.joinTournament(playerId: pid, deckId: d.id);
    }

    seat(host.playerId, 'Domain Zoo');
    seat(c.resolveSession('Alice', null).playerId, 'Red');
    seat(c.resolveSession('Bob', null).playerId, 'Blue');
    seat(c.resolveSession('Carol', null).playerId, 'Green');
    c.startTournament();

    // report ONE match and partially confirm — a realistic mid-round crash point
    final m = c.engine!.currentRound.matches.firstWhere((x) => !x.isBye);
    c.submitResult(playerId: m.p1Id, matchId: m.id, mineWon: 2, oppWon: 1);
    c.submitResult(playerId: m.p2Id!, matchId: m.id, mineWon: 1, oppWon: 2);
    c.confirmInfraction(playerId: m.p1Id, matchId: m.id, ok: true);

    // simulate crash + restart: brand-new controller, same store
    final c2 = ServerController(rng: Random(99))..store = store;
    c2.loadFromStore();

    expect(c2.joinCode, c.joinCode);
    expect(c2.hostPlayerId, host.playerId);
    expect(c2.players.length, 4);
    expect(c2.decks.length, 4);
    expect(c2.engine!.status, TournamentStatus.running);

    final m2 = c2.engine!.currentRound.matches.firstWhere((x) => x.id == m.id);
    expect(m2.accepted, const GameScore(2, 1)); // accepted result survived
    expect(
      m2.infraction[m.p1Id],
      isTrue,
    ); // pending-confirmation state survived
    expect(
      c2.decks.values.map((d) => d.name).toSet(),
      containsAll({'Domain Zoo', 'Red', 'Blue', 'Green'}),
    );
    expect(c2.snapshotFor(host.playerId)['phase'], 'running');
  });

  test('clearTournament ends the event but keeps durable players/decks', () {
    final store = MemoryPersistence();
    final c = ServerController(rng: Random(1))..store = store;
    final h = c.resolveSession('Host', null);
    c.createTournament(name: 'X', hostPlayerId: h.playerId);
    final d = c.saveDeck(
      ownerId: h.playerId,
      name: 'Zoo',
      mainboard: '',
      sideboard: '',
    );
    c.joinTournament(playerId: h.playerId, deckId: d.id);

    c.clearTournament();
    expect(c.joinCode, isNull);
    expect(c.engine, isNull);
    expect(c.players.length, 1); // durable identity preserved
    expect(c.decks.length, 1); // durable deck preserved

    final c2 = ServerController()..store = store;
    c2.loadFromStore();
    expect(c2.joinCode, isNull);
    expect(c2.players.length, 1);
  });

  test('a malformed backup import leaves the existing state untouched', () {
    final c = ServerController(rng: Random(7));
    final owner = c.ensureOwner('Host');
    c.saveDeck(
      ownerId: owner.playerId,
      name: 'Domain Zoo',
      mainboard: '4 Tribal Flames',
      sideboard: '2 Rest in Peace',
    );
    final before = c.exportJson();
    final corrupt = jsonDecode(before) as Map<String, dynamic>;
    corrupt['tokens'] = <String>[]; // fails after players/decks were decoded

    expect(c.importJson(jsonEncode(corrupt)), isFalse);
    expect(c.exportJson(), before);
  });

  test('online hosting mode survives a crash-resume round trip', () {
    final store = MemoryPersistence();
    final c = ServerController(rng: Random(31))..store = store;
    final host = c.resolveSession('Host', null);
    c.createTournament(
      name: 'Internet Cup',
      hostPlayerId: host.playerId,
      mode: HostingMode.online,
    );

    final restored = ServerController()..store = store;
    restored.loadFromStore();

    expect(restored.hostingMode, HostingMode.online);
  });

  test('legacy active saves without a hosting mode resume as LAN', () {
    final c = ServerController(rng: Random(32));
    final host = c.resolveSession('Host', null);
    c.createTournament(name: 'Legacy Cup', hostPlayerId: host.playerId);
    final legacy = jsonDecode(c.exportJson()) as Map<String, dynamic>
      ..remove('hostingMode');

    final restored = ServerController();
    expect(restored.importJson(jsonEncode(legacy)), isTrue);
    expect(restored.hostingMode, HostingMode.lan);
  });

  test('ending an event clears its hosting mode', () {
    final c = ServerController(rng: Random(33));
    final host = c.resolveSession('Host', null);
    c.createTournament(
      name: 'Internet Cup',
      hostPlayerId: host.playerId,
      mode: HostingMode.online,
    );

    c.clearTournament();

    expect(c.hostingMode, isNull);
  });
}
