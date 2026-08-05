import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/server.dart';
import 'package:mtg_tourney/shared/tournament_engine.dart';
import 'package:shelf/shelf.dart';

/// Regression coverage for the bug-fix batch:
///  - #1 auto-fetch wiring: [ServerController.onDeckSaved] fires for every saved
///    deck (organizer AND a participant via POST /api/deck), so the host can
///    resolve+cache images in the background.
///  - #4 infraction surfacing: a reported infraction reaches the host snapshot
///    (isInfraction / reportedBy / attentionCount) and [pendingReviewCount].
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
    'onDeckSaved fires for organizer saves AND participant /api/deck uploads',
    () async {
      final c = ServerController(rng: Random(1));
      final saved = <String>[];
      c.onDeckSaved = saved.add;

      // Organizer / direct save.
      final d = c.saveDeck(
        ownerId: 'p1',
        name: 'Zoo',
        mainboard: '4 Ragavan',
        sideboard: '',
      );
      expect(saved, [d.id]);

      // Participant path through the REST handler (this used to be a dead end:
      // no persist, no broadcast, no resolve).
      final host = c.resolveSession('Host', null);
      c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
      final alice = c.resolveSession('Alice', null);
      final h = buildHandler(c);
      final r = await post(h, '/api/deck', {
        'token': alice.token,
        'name': 'Burn',
        'mainboard': '4 Bolt',
      });
      expect(r['status'], 200);
      expect(saved, contains(r['deckId']));
    },
  );

  test('a reported infraction surfaces in the host snapshot', () {
    final c = ServerController(rng: Random(2));
    final host = c.resolveSession('Giuseppe', null);
    c.createTournament(name: 'FNM', hostPlayerId: host.playerId);
    final alice = c.resolveSession('Alice', null);
    final hd = c.saveDeck(
      ownerId: host.playerId,
      name: 'Zoo',
      mainboard: '',
      sideboard: '',
    );
    final ad = c.saveDeck(
      ownerId: alice.playerId,
      name: 'Burn',
      mainboard: '',
      sideboard: '',
    );
    c.joinTournament(playerId: host.playerId, deckId: hd.id);
    c.joinTournament(playerId: alice.playerId, deckId: ad.id);
    c.startTournament();

    final matchId = c.engine!.currentRound.matches.first.id;
    // Both agree on the score → accepted + revealed.
    c.submitResult(
      playerId: host.playerId,
      matchId: matchId,
      mineWon: 2,
      oppWon: 0,
    );
    c.submitResult(
      playerId: alice.playerId,
      matchId: matchId,
      mineWon: 0,
      oppWon: 2,
    );
    expect(c.pendingReviewCount, 0);

    // Alice flags an infraction.
    c.confirmInfraction(playerId: alice.playerId, matchId: matchId, ok: false);
    expect(c.pendingReviewCount, 1);

    final snap = c.snapshotFor(host.playerId);
    expect(snap['attentionCount'], 1);
    final pairing = (snap['pairings'] as List).first as Map;
    expect(pairing['needsReview'], true);
    expect(pairing['isInfraction'], true);
    expect(pairing['reportedBy'], contains('Alice'));

    // Adjudication details are host-only; players see only their own match.
    final playerSnap = c.snapshotFor(alice.playerId);
    expect(playerSnap['pairings'], isEmpty);
    expect(playerSnap['attentionCount'], 0);
  });

  test(
    'a result mismatch surfaces each player\'s declared score to the host',
    () {
      final c = ServerController(rng: Random(7));
      final host = c.resolveSession('Giuseppe', null);
      c.createTournament(name: 'FNM', hostPlayerId: host.playerId);
      final alice = c.resolveSession('Antonio', null);
      final hd = c.saveDeck(
        ownerId: host.playerId,
        name: 'Grixis',
        mainboard: '',
        sideboard: '',
      );
      final ad = c.saveDeck(
        ownerId: alice.playerId,
        name: 'Neobrand',
        mainboard: '',
        sideboard: '',
      );
      c.joinTournament(playerId: host.playerId, deckId: hd.id);
      c.joinTournament(playerId: alice.playerId, deckId: ad.id);
      c.startTournament();
      final matchId = c.engine!.currentRound.matches.first.id;
      // Both claim they won — a genuine mismatch (not a hardcoded 2–1).
      c.submitResult(
        playerId: host.playerId,
        matchId: matchId,
        mineWon: 2,
        oppWon: 0,
      );
      c.submitResult(
        playerId: alice.playerId,
        matchId: matchId,
        mineWon: 2,
        oppWon: 1,
      );

      final pairing =
          (c.snapshotFor(host.playerId)['pairings'] as List).first as Map;
      expect(pairing['needsReview'], true);
      expect(pairing['reviewReason'], 'resultMismatch');
      final reports = (pairing['reports'] as List).cast<Map>();
      expect(reports.length, 2);
      expect(reports.map((r) => r['by']).toSet(), {'Giuseppe', 'Antonio'});
      // The two declared scores genuinely differ (this is what the host now sees
      // instead of a fabricated 2–1).
      expect(reports.map((r) => '${r['p1']}-${r['p2']}').toSet().length, 2);
    },
  );

  test('a player cannot enter the tournament with another player\'s deck', () {
    final c = ServerController(rng: Random(3));
    final host = c.resolveSession('Host', null);
    c.createTournament(name: 'Cup', hostPlayerId: host.playerId);
    final alice = c.resolveSession('Alice', null);
    final bob = c.resolveSession('Bob', null);
    final aliceDeck = c.saveDeck(
      ownerId: alice.playerId,
      name: 'Burn',
      mainboard: '',
      sideboard: '',
    );
    // Bob may not seat himself with Alice's deck (would expose her list at reveal).
    expect(
      () => c.joinTournament(playerId: bob.playerId, deckId: aliceDeck.id),
      throwsA(isA<EngineError>()),
    );
    // Alice can enter with her own deck.
    c.joinTournament(playerId: alice.playerId, deckId: aliceDeck.id);
  });

  test(
    '/api/host/create cannot be used by a non-host to wipe a running event',
    () async {
      final c = ServerController(rng: Random(4));
      final h = buildHandler(c);
      // Host bootstraps the first event over HTTP (open, no host exists yet).
      final created = await post(h, '/api/host/create', {
        'nickname': 'Host',
        'name': 'Cup',
      });
      expect(created['status'], 200);
      final engineId1 = c.engine!.id;
      // A stranger (no host token) cannot create over the top of the live event.
      final attack = await post(h, '/api/host/create', {
        'nickname': 'Mallory',
        'name': 'Hijack',
      });
      expect(attack['status'], 403);
      expect(c.engine!.id, engineId1); // original event left intact
      // The real host CAN replace it.
      final recreate = await post(h, '/api/host/create', {
        'token': created['token'],
        'nickname': 'Host',
        'name': 'Cup 2',
      });
      expect(recreate['status'], 200);
    },
  );
}
