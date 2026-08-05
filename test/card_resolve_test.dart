import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/host/host_controller.dart';
import 'package:mtg_tourney/services/card_cache.dart';
import 'package:mtg_tourney/services/scryfall.dart';
import 'package:mtg_tourney/shared/cards.dart';

/// Offline fake of the Scryfall source so the resolve→cache pipeline can be
/// unit-tested without a network.
class _FakeSource implements CardSource {
  final Map<String, CardInfo> byName;
  int imageFetches = 0;
  int singleResolves = 0;
  int batchCalls = 0;
  _FakeSource(this.byName);

  @override
  Future<CardInfo?> resolve(String name) async {
    singleResolves++;
    return byName[name.toLowerCase().trim()];
  }

  @override
  Future<Map<String, CardInfo>> resolveAll(List<String> names) async {
    batchCalls++;
    return {
      for (final n in names)
        n.toLowerCase().trim(): ?byName[n.toLowerCase().trim()],
    };
  }

  @override
  Future<List<String>> autocomplete(String q) async => byName.values
      .map((c) => c.name)
      .where((n) => n.toLowerCase().contains(q.toLowerCase()))
      .toList();

  @override
  Future<List<int>> fetchImage(String url) async {
    imageFetches++;
    return const [0xFF, 0xD8, 0xFF]; // jpeg magic-ish bytes
  }
}

void main() {
  const bolt = CardInfo(
    id: 'bolt',
    name: 'Lightning Bolt',
    typeLine: 'Instant',
    setCode: 'm10',
    imageUrl: 'http://x/b.jpg',
  );
  const mtn = CardInfo(
    id: 'mtn',
    name: 'Mountain',
    typeLine: 'Basic Land — Mountain',
    setCode: 'm10',
    imageUrl: 'http://x/m.jpg',
  );

  HostController host(Directory cacheDir, _FakeSource src) {
    final c = HostController();
    c.cardSource = src;
    c.imageCache = CardImageCache(cacheDir);
    return c;
  }

  test(
    'resolveDeckFromText builds structured cards from text and caches images',
    () async {
      final dir = Directory.systemTemp.createTempSync('mtg_cards');
      final src = _FakeSource({'lightning bolt': bolt, 'mountain': mtn});
      final c = host(dir, src);
      final d = c.server.saveDeck(
        ownerId: 'p',
        name: 'Burn',
        mainboard: '4 Lightning Bolt\n16 Mountain',
        sideboard: '2 Lightning Bolt',
      );

      final progress = <int>[];
      await c.resolveDeckFromText(
        d.id,
        onProgress: (done, total) => progress.add(total),
      );

      final updated = c.server.decks[d.id]!;
      expect(updated.hasCards, isTrue);
      expect(updated.mainCards.firstWhere((e) => e.cardId == 'bolt').qty, 4);
      expect(updated.mainCards.firstWhere((e) => e.cardId == 'mtn').qty, 16);
      expect(updated.sideCards.single.cardId, 'bolt');
      expect(
        updated.mainboardText,
        contains('4 Lightning Bolt'),
      ); // text regenerated
      expect(c.imageCache!.isCached('bolt'), isTrue);
      expect(c.imageCache!.isCached('mtn'), isTrue);
      expect(progress.last, 3); // 2 main lines + 1 side line
      // Unknown names are asked for in batched requests — at most one per
      // resolve pass (saveDeck also kicks off a background pass), never one
      // round trip per card, which is what made importing a deck slow.
      expect(src.batchCalls, lessThanOrEqualTo(2));
      expect(src.singleResolves, 0);

      c.dispose();
      dir.deleteSync(recursive: true);
    },
  );

  test(
    'downloadAllDeckImages caches missing images for structured decks',
    () async {
      final dir = Directory.systemTemp.createTempSync('mtg_cards2');
      final src = _FakeSource({});
      final c = host(dir, src);
      c.server.registerCards([bolt, mtn]);
      final d = c.server.saveDeck(
        ownerId: 'p',
        name: 'Burn',
        mainboard: '',
        sideboard: '',
      );
      c.server.setDeckCards(
        deckId: d.id,
        main: const [DeckCardEntry('bolt', 4), DeckCardEntry('mtn', 16)],
        side: const [],
      );
      expect(c.imageCache!.isCached('bolt'), isFalse);

      final r = await c.downloadAllDeckImages();
      expect(r.requested, 2);
      expect(r.imagesCached, 2);
      expect(r.imagesFailed, 0);
      expect(src.imageFetches, 2);
      expect(c.imageCache!.isCached('bolt'), isTrue);
      expect(c.imageCache!.isCached('mtn'), isTrue);

      c.dispose();
      dir.deleteSync(recursive: true);
    },
  );

  test(
    'partial resolve keeps resolved cards but preserves the original text',
    () async {
      final dir = Directory.systemTemp.createTempSync('mtg_cards3');
      final src = _FakeSource({
        'lightning bolt': bolt,
      }); // "Mountain" is unknown -> fails
      final c = host(dir, src);
      final d = c.server.saveDeck(
        ownerId: 'p',
        name: 'Burn',
        mainboard: '4 Lightning Bolt\n16 Mountain',
        sideboard: '',
      );

      final summary = await c.resolveDeckFromText(d.id);
      final updated = c.server.decks[d.id]!;

      expect(summary.resolved, 1);
      expect(summary.failed, 1);
      expect(summary.failedNames, contains('Mountain'));
      expect(updated.mainCards.single.cardId, 'bolt'); // resolved card kept
      // The user's original list is NOT clobbered by the resolved subset.
      expect(updated.mainboardText, contains('16 Mountain'));

      c.dispose();
      dir.deleteSync(recursive: true);
    },
  );

  test(
    'fully-failed (offline) resolve stores no cards and never loses the text',
    () async {
      final dir = Directory.systemTemp.createTempSync('mtg_cards4');
      final src = _FakeSource({}); // nothing resolves — simulates being offline
      final c = host(dir, src);
      final d = c.server.saveDeck(
        ownerId: 'p',
        name: 'Burn',
        mainboard: '4 Lightning Bolt\n16 Mountain',
        sideboard: '2 Lightning Bolt',
      );

      final summary = await c.resolveDeckFromText(d.id);
      final updated = c.server.decks[d.id]!;

      expect(summary.resolved, 0);
      expect(summary.failed, 3);
      expect(updated.hasCards, isFalse); // nothing structured was stored
      expect(
        updated.mainboardText,
        contains('4 Lightning Bolt'),
      ); // text intact
      expect(updated.mainboardText, contains('16 Mountain'));
      expect(updated.sideboardText, contains('2 Lightning Bolt'));

      c.dispose();
      dir.deleteSync(recursive: true);
    },
  );
}
