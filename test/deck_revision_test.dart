import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/deck_revision.dart';
import 'package:mtg_tourney/shared/models.dart';

import 'stats_fixture.dart';

/// Deck revisions exist so that editing a deck cannot rewrite what you played
/// last season. These tests hold that line.
void main() {
  Deck deck({
    String id = 'd1',
    String name = 'Domain Zoo',
    String archetype = '',
    String main = '4 Ragavan\n4 Lightning Bolt',
    String side = '2 Abrade',
  }) => Deck(
    id: id,
    ownerId: 'p1',
    name: name,
    archetype: archetype,
    mainboardText: main,
    sideboardText: side,
  );

  group('content addressing', () {
    test(
      'the same list produces the same revision id, order-independently',
      () {
        final at = DateTime.utc(2026, 2, 1);
        final a = DeckRevision.of(deck(), revision: 1, at: at);
        final b = DeckRevision.of(
          deck(main: '4 Lightning Bolt\n4 Ragavan'),
          revision: 9,
          at: at.add(const Duration(days: 30)),
        );
        expect(b.id, a.id, reason: 'reordering a list is not a new list');
      },
    );

    test('changing a card changes the id', () {
      final at = DateTime.utc(2026, 2, 1);
      final a = DeckRevision.of(deck(), revision: 1, at: at);
      final b = DeckRevision.of(
        deck(main: '4 Ragavan\n3 Lightning Bolt\n1 Galvanic Blast'),
        revision: 2,
        at: at,
      );
      expect(b.id, isNot(a.id));
    });

    test(
      'renaming the deck is a new revision, since history shows the name',
      () {
        final at = DateTime.utc(2026, 2, 1);
        final a = DeckRevision.of(deck(), revision: 1, at: at);
        final b = DeckRevision.of(deck(name: 'Boros Zoo'), revision: 2, at: at);
        expect(b.id, isNot(a.id));
      },
    );
  });

  group('diffs', () {
    test('reports cards added and removed per board', () {
      final at = DateTime.utc(2026, 2, 1);
      final v1 = DeckRevision.of(deck(), revision: 1, at: at);
      final v2 = DeckRevision.of(
        deck(main: '4 Ragavan\n2 Lightning Bolt\n2 Galvanic Blast', side: ''),
        revision: 2,
        at: at,
      );
      final diff = DeckDiff.between(v1, v2);
      expect(diff.main.added, {'Galvanic Blast': 2});
      expect(diff.main.removed, {'Lightning Bolt': 2});
      expect(diff.side.removed, {'Abrade': 2});
      expect(diff.isEmpty, isFalse);
      expect(diff.changedCards, greaterThan(0));
    });

    test('an identical list diffs to nothing', () {
      final at = DateTime.utc(2026, 2, 1);
      final v1 = DeckRevision.of(deck(), revision: 1, at: at);
      final v2 = DeckRevision.of(deck(), revision: 2, at: at);
      expect(DeckDiff.between(v1, v2).isEmpty, isTrue);
    });
  });

  group('entering a tournament freezes the list', () {
    test('editing the deck afterwards does not change the played list', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ana = enrol(
        c,
        'Ana',
        deckName: 'Domain Zoo',
        main: '4 Ragavan\n4 Lightning Bolt',
      );
      final bo = enrol(c, 'Bo', deckName: 'Mono-Red', main: '4 Goblin Guide');
      c.createTournament(name: 'Friday', hostPlayerId: ana.playerId);
      c.joinTournament(playerId: ana.playerId, deckId: ana.deckId);
      c.joinTournament(playerId: bo.playerId, deckId: bo.deckId);

      final entry = c.engine!.entryOf(ana.playerId)!;
      final frozen = c.revisionOf(entry)!;
      expect(frozen.mainboardText, contains('Ragavan'));
      expect(frozen.migrated, isFalse);

      c.startTournament();
      confirmMatch(c, firstRealMatch(c), 2, 0);
      c.clearTournament();

      // Now rebuild the deck completely.
      c.saveDeck(
        ownerId: ana.playerId,
        deckId: ana.deckId,
        name: 'Domain Zoo',
        mainboard: '4 Psychic Frog',
        sideboard: '',
      );
      expect(c.decks[ana.deckId]!.mainboardText, '4 Psychic Frog');

      final archived = c.archive.single.entryOf(ana.playerId)!;
      final played = c.revisionOf(archived)!;
      expect(played.id, frozen.id);
      expect(played.mainboardText, contains('Ragavan'));
      expect(played.mainboardText, isNot(contains('Psychic Frog')));
    });

    test('re-entering an unchanged deck reuses the revision', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      runTwoPlayerEvent(c, name: 'One');
      final after = c.deckRevisions.length;
      clock.advance(const Duration(days: 7));

      // Second event, same decks, nothing edited.
      final ana = c.players.values.firstWhere((p) => p.nickname == 'Ana');
      final bo = c.players.values.firstWhere((p) => p.nickname == 'Bo');
      c.createTournament(name: 'Two', hostPlayerId: ana.id);
      c.joinTournament(playerId: ana.id, deckId: c.decksOf(ana.id).single.id);
      c.joinTournament(playerId: bo.id, deckId: c.decksOf(bo.id).single.id);
      expect(c.deckRevisions.length, after);
    });

    test('editing between events produces a second revision', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runTwoPlayerEvent(c, name: 'One');
      c.saveDeck(
        ownerId: ids.aId,
        deckId: ids.aDeck,
        name: 'Domain Zoo',
        mainboard: '4 Psychic Frog',
        sideboard: '',
      );
      c.createTournament(name: 'Two', hostPlayerId: ids.aId);
      c.joinTournament(playerId: ids.aId, deckId: ids.aDeck);
      expect(c.revisionsOf(ids.aDeck), hasLength(2));
      expect(c.revisionsOf(ids.aDeck).last.revision, 2);
    });
  });

  group('migration from a pre-revision save', () {
    test(
      'back-fills a flagged revision and keeps the rest of the save intact',
      () {
        final clock = TestClock();
        final store = MemoryPersistence();
        final c = controllerWith(clock, store: store);
        final ids = runTwoPlayerEvent(c, name: 'Legacy Night');

        // Simulate an old save: strip revisions and the entries' pointers.
        final legacy = c.toJson()
          ..remove('revisions')
          ..remove('schema');
        for (final t in (legacy['archive'] as List)) {
          for (final e in ((t as Map)['entries'] as List)) {
            (e as Map).remove('revisionId');
          }
        }
        store.save(jsonEncode(legacy));

        final restored = controllerWith(clock, store: store)..loadFromStore();
        expect(restored.archive, hasLength(1));
        final entry = restored.archive.single.entryOf(ids.aId)!;
        final revision = restored.revisionOf(entry);
        expect(revision, isNotNull);
        expect(
          revision!.migrated,
          isTrue,
          reason: 'a reconstructed list must never claim to be the played one',
        );
        expect(revision.deckId, ids.aDeck);
        // Statistics still work over migrated data.
        expect(restored.statistics.facts, hasLength(1));
      },
    );

    test('a save with no decks left leaves the entry honestly unknown', () {
      final clock = TestClock();
      final c = controllerWith(clock);
      final ids = runTwoPlayerEvent(c, name: 'Legacy');
      // Drop the pointer *and* the deck, as a partial old backup would.
      c.archive.single.entryOf(ids.aId)!.deckRevisionId = null;
      c.decks.remove(ids.aDeck);
      expect(c.migrateMissingRevisions(), 0);
      expect(c.revisionOf(c.archive.single.entryOf(ids.aId)!), isNull);
    });
  });
}
