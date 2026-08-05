import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/services/export_data.dart';

void main() {
  test('export is gzipped JSON, carries history, and leaks no credentials', () {
    final c = ServerController(rng: Random(3));
    final host = c.resolveSession('Host', null);
    c.saveDeck(
      ownerId: host.playerId,
      name: 'Domain Zoo',
      mainboard: '4 Ragavan',
      sideboard: '',
    );
    c.createTournament(name: 'Cup', hostPlayerId: host.playerId);

    final export = buildExport(c, DateTime.utc(2026, 8, 5));
    expect(export.name, 'mtg-tourney-2026-08-05.json.gz');

    final raw = utf8.decode(gzip.decode(export.bytes));
    expect(export.bytes.length, lessThan(utf8.encode(raw).length));

    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect((json['decks'] as List).single['name'], 'Domain Zoo');
    for (final secret in ['tokens', 'ownerToken', 'joinCode', 'hostingMode']) {
      expect(json.containsKey(secret), isFalse, reason: secret);
    }
    expect(raw.contains(host.token), isFalse);

    // An export with credentials stripped must still restore.
    final restored = ServerController(rng: Random(4));
    expect(restored.importJson(raw), isTrue);
    expect(restored.decksOf(host.playerId).single.name, 'Domain Zoo');
  });
}
