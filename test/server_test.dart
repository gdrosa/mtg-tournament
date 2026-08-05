import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/server.dart';
import 'package:shelf/shelf.dart';

/// Drives the embedded LAN HTTP handler in-memory (no socket) to lock down the
/// REST surface that browser players hit.
void main() {
  Future<Map<String, dynamic>> post(
    Handler h,
    String path,
    Map<String, Object?> body,
  ) async {
    final resp = await h(
      Request(
        'POST',
        Uri.parse('http://x$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
    final text = await resp.readAsString();
    final data = text.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(text) as Map<String, dynamic>;
    return {'status': resp.statusCode, ...data};
  }

  test(
    '/api/deck never trusts a client-supplied deckId (no injection / no hijack)',
    () async {
      final c = ServerController(rng: Random(11));
      final host = c.resolveSession('Host', null);
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
      final alice = c.resolveSession('Alice', null);
      final h = buildHandler(c);

      // A poison id is ignored — the server mints a fresh uuid instead, so it can
      // never be reflected back into the DOM as executable text.
      const poison = "x');alert(1);//";
      final r1 = await post(h, '/api/deck', {
        'token': alice.token,
        'name': 'Deck',
        'deckId': poison,
      });
      expect(r1['status'], 200);
      expect(r1['deckId'], isNot(poison));
      expect(c.decks.containsKey(poison), isFalse);

      // Editing a deck the caller owns DOES reuse its id.
      final owned = r1['deckId'] as String;
      final r2 = await post(h, '/api/deck', {
        'token': alice.token,
        'name': 'Deck v2',
        'deckId': owned,
      });
      expect(r2['deckId'], owned);
      expect(c.decks[owned]!.name, 'Deck v2');

      // Another player cannot hijack Alice's deck by passing her deckId.
      final r3 = await post(h, '/api/deck', {
        'token': host.token,
        'name': 'Steal',
        'deckId': owned,
      });
      expect(r3['deckId'], isNot(owned));
      expect(c.decks[owned]!.ownerId, alice.playerId);
    },
  );

  test(
    '/api/deck rejects edits to a deck locked into a running event',
    () async {
      final c = ServerController(rng: Random(12));
      final host = c.resolveSession('Host', null);
      final alice = c.resolveSession('Alice', null);
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
      final hostDeck = c.saveDeck(
        ownerId: host.playerId,
        name: 'Control',
        mainboard: '4 Counterspell',
        sideboard: '',
      );
      final aliceDeck = c.saveDeck(
        ownerId: alice.playerId,
        name: 'Burn',
        mainboard: '4 Lightning Bolt',
        sideboard: '',
      );
      c.joinTournament(playerId: host.playerId, deckId: hostDeck.id);
      c.joinTournament(playerId: alice.playerId, deckId: aliceDeck.id);
      c.startTournament();

      final h = buildHandler(c);
      final response = await post(h, '/api/deck', {
        'token': alice.token,
        'deckId': aliceDeck.id,
        'name': 'Changed after start',
      });

      expect(response['status'], 400);
      expect(response['error'], contains('locked'));
      expect(c.decks[aliceDeck.id]!.name, 'Burn');
    },
  );

  test('an unknown client token is replaced with a server-generated token', () {
    final c = ServerController(rng: Random(13));

    final session = c.resolveSession('Mallory', 'attacker-chosen-token');

    expect(session.token, isNot('attacker-chosen-token'));
    expect(c.playerIdForToken('attacker-chosen-token'), isNull);
    expect(c.playerIdForToken(session.token), session.playerId);
  });

  test(
    'player-facing APIs reject fields that could inflate snapshots',
    () async {
      final c = ServerController(rng: Random(14));
      final host = c.resolveSession('Host', null);
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
      final h = buildHandler(c);

      final oversizedNickname = await post(h, '/api/join', {
        'nickname': List.filled(maxNicknameLength + 1, 'N').join(),
        'code': c.joinCode,
      });
      expect(oversizedNickname['status'], 400);
      expect(c.players, hasLength(1));

      final joined = await post(h, '/api/join', {
        'nickname': 'Alice',
        'code': c.joinCode,
      });
      expect(joined['status'], 200);
      final token = joined['token'] as String;

      final oversizedName = await post(h, '/api/deck', {
        'token': token,
        'name': List.filled(maxDeckNameLength + 1, 'D').join(),
      });
      expect(oversizedName['status'], 400);

      final oversizedList = await post(h, '/api/deck', {
        'token': token,
        'name': 'Deck',
        'mainboard': List.filled(maxMainboardLength + 1, 'x').join(),
      });
      expect(oversizedList['status'], 400);
      expect(c.decks, isEmpty);
    },
  );
}
