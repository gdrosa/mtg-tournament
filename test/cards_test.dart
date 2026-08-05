import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/persistence.dart';
import 'package:mtg_tourney/shared/cards.dart';

void main() {
  group('categorize', () {
    test('files multi-type cards by decklist convention', () {
      expect(categorize('Instant'), CardCategory.instant);
      expect(categorize('Sorcery'), CardCategory.sorcery);
      expect(
        categorize('Legendary Creature — Elf Druid'),
        CardCategory.creature,
      );
      expect(
        categorize('Artifact Creature — Construct'),
        CardCategory.creature,
      ); // creature wins
      expect(
        categorize('Artifact Land'),
        CardCategory.land,
      ); // land before artifact
      expect(categorize('Enchantment — Aura'), CardCategory.enchantment);
      expect(categorize('Artifact — Equipment'), CardCategory.artifact);
      expect(categorize('Planeswalker — Jace'), CardCategory.planeswalker);
      expect(categorize('Basic Land — Island'), CardCategory.land);
      expect(categorize('Conspiracy'), CardCategory.other);
    });
  });

  group('parseDecklist', () {
    test('handles common formats, qty default, and skips noise', () {
      final lines = parseDecklist('''
4 Lightning Bolt
4x Goblin Guide
Island
2 Lightning Bolt (2X2) 117

# a comment
// another
Sideboard
3 Smash to Smithereens
''');
      expect(lines.map((l) => '${l.qty} ${l.name}').toList(), [
        '4 Lightning Bolt',
        '4 Goblin Guide',
        '1 Island',
        '2 Lightning Bolt', // printing tag stripped
        '3 Smash to Smithereens', // "Sideboard" header skipped
      ]);
    });
  });

  group('cardInfoFromScryfall', () {
    test('maps a single-faced card incl. its normal image', () {
      final ci = cardInfoFromScryfall({
        'id': 'abc',
        'name': 'Lightning Bolt',
        'type_line': 'Instant',
        'set': 'm10',
        'collector_number': '146',
        'image_uris': {'normal': 'http://img/bolt.jpg'},
      });
      expect(ci, isNotNull);
      expect(ci!.name, 'Lightning Bolt');
      expect(ci.category, CardCategory.instant);
      expect(ci.imageUrl, 'http://img/bolt.jpg');
    });

    test('uses the front face image for a double-faced card', () {
      expect(
        scryfallImageUrl({
          'card_faces': [
            {
              'image_uris': {'normal': 'http://img/front.jpg'},
            },
            {
              'image_uris': {'normal': 'http://img/back.jpg'},
            },
          ],
        }),
        'http://img/front.jpg',
      );
    });

    test(
      'keeps an image-less card with an empty url instead of discarding it',
      () {
        // Regression: a valid card whose JSON has no resolvable image must NOT
        // vanish from the decklist — it should resolve with an empty imageUrl.
        final ci = cardInfoFromScryfall({
          'id': 'noimg',
          'name': 'Weird Layout',
          'type_line': 'Artifact',
        });
        expect(ci, isNotNull);
        expect(ci!.id, 'noimg');
        expect(ci.imageUrl, '');
      },
    );

    test('returns null only when there is no usable id', () {
      expect(cardInfoFromScryfall({'name': 'No Id'}), isNull);
      expect(cardInfoFromScryfall({'id': ''}), isNull);
    });
  });

  test('renderDecklist + deckCount round-trip via a name lookup', () {
    final names = {'a': 'Lightning Bolt', 'b': 'Island'};
    final entries = [const DeckCardEntry('a', 4), const DeckCardEntry('b', 17)];
    expect(
      renderDecklist(entries, (id) => names[id]),
      '4 Lightning Bolt\n17 Island',
    );
    expect(deckCount(entries), 21);
  });

  test(
    'controller stores card catalog and exposes it in the opponent reveal',
    () {
      final c = ServerController(rng: Random(1));
      final host = c.ensureOwner('Host');
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);

      // a deck with structured cards + catalog metadata
      final bolt = const CardInfo(
        id: 'bolt',
        name: 'Lightning Bolt',
        typeLine: 'Instant',
        setCode: 'm10',
        imageUrl: 'http://x/bolt.jpg',
      );
      final mountain = const CardInfo(
        id: 'mtn',
        name: 'Mountain',
        typeLine: 'Basic Land — Mountain',
        setCode: 'm10',
        imageUrl: 'http://x/m.jpg',
      );
      c.registerCards([bolt, mountain]);
      final deck = c.saveDeck(
        ownerId: host.playerId,
        name: 'Burn',
        mainboard: '',
        sideboard: '',
      );
      c.setDeckCards(
        deckId: deck.id,
        main: [const DeckCardEntry('bolt', 4), const DeckCardEntry('mtn', 16)],
        side: [const DeckCardEntry('bolt', 2)],
      );
      c.joinTournament(playerId: host.playerId, deckId: deck.id);

      // text is regenerated from the structured cards
      expect(c.decks[deck.id]!.mainboardText, contains('4 Lightning Bolt'));
      expect(c.decks[deck.id]!.hasCards, isTrue);

      // seat an opponent, start, both report, reveal exposes structured cards
      final alice = c.resolveSession('Alice', null);
      final ad = c.saveDeck(
        ownerId: alice.playerId,
        name: 'Deck',
        mainboard: '',
        sideboard: '',
      );
      c.joinTournament(playerId: alice.playerId, deckId: ad.id);
      c.startTournament();
      final m = c.engine!.currentRound.matches.firstWhere((x) => !x.isBye);
      c.submitResult(playerId: m.p1Id, matchId: m.id, mineWon: 2, oppWon: 1);
      c.submitResult(playerId: m.p2Id!, matchId: m.id, mineWon: 1, oppWon: 2);

      // the loser sees the winner's structured deck (whoever the host is)
      final hostView = c.snapshotFor(host.playerId)['yourMatch'] as Map;
      final oppView =
          c.snapshotFor(m.opponentOf(host.playerId)!)['yourMatch'] as Map;
      final deckView =
          (hostView['revealed'] == true ? hostView : oppView)['opponentDeck']
              as Map?;
      // find whichever side revealed the Burn deck
      final burnReveal = [hostView, oppView]
          .map((v) => v['opponentDeck'] as Map?)
          .firstWhere(
            (d) => d != null && d['name'] == 'Burn',
            orElse: () => deckView,
          );
      expect(burnReveal, isNotNull);
      final cards = (burnReveal!['cards'] as List).cast<Map>();
      expect(cards.where((x) => x['board'] == 'main'), hasLength(2));
      expect(
        cards.firstWhere((x) => x['id'] == 'bolt')['img'],
        '/cards/img/bolt',
      );
      expect(cards.firstWhere((x) => x['id'] == 'mtn')['category'], 'land');
    },
  );

  test('card catalog round-trips through persistence', () {
    final store = MemoryPersistence();
    final c = ServerController(rng: Random(2))..store = store;
    c.registerCards([
      const CardInfo(
        id: 'x',
        name: 'Counterspell',
        typeLine: 'Instant',
        setCode: 'mh2',
        imageUrl: 'http://i/x.jpg',
      ),
    ]);
    c.persistAndNotify();

    final restored = ServerController(rng: Random(2))..store = store;
    restored.loadFromStore();
    expect(restored.cardCatalog['x']?.name, 'Counterspell');
    expect(restored.cardCatalog['x']?.category, CardCategory.instant);
  });
}
