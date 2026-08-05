import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/host/online_relay.dart';
import 'package:mtg_tourney/server/controller.dart';

void main() {
  group('OnlineRelaySession', () {
    test('round-trips credentials and event binding', () {
      const session = OnlineRelaySession(
        roomId: 'abcdefghijklmnopqrstuvwx',
        hostSecret: 'private-secret-value-at-least-twenty-chars',
        joinUrl: 'https://relay.example/r/abcdefghijklmnopqrstuvwx/',
        expiresAtEpochMs: 4102444800000,
        eventId: 'event-1',
      );

      final decoded = OnlineRelaySession.fromJson(session.toJson());

      expect(decoded.roomId, session.roomId);
      expect(decoded.hostSecret, session.hostSecret);
      expect(decoded.joinUrl, session.joinUrl);
      expect(decoded.expiresAtEpochMs, session.expiresAtEpochMs);
      expect(decoded.eventId, session.eventId);
    });

    test('detects expired rooms and relay-origin changes', () {
      const session = OnlineRelaySession(
        roomId: 'abcdefghijklmnopqrstuvwx',
        hostSecret: 'private-secret-value-at-least-twenty-chars',
        joinUrl: 'https://relay.example/r/abcdefghijklmnopqrstuvwx/',
        expiresAtEpochMs: 1893456000000,
      );

      expect(
        session.isExpired(now: DateTime.utc(2029, 12, 31, 23, 58)),
        isFalse,
      );
      expect(
        session.isExpired(now: DateTime.utc(2029, 12, 31, 23, 59)),
        isTrue,
      );
      expect(session.belongsTo(Uri.parse('https://relay.example')), isTrue);
      expect(session.belongsTo(Uri.parse('https://other.example')), isFalse);
    });

    test('rejects truncated credentials and mismatched join URLs', () {
      final valid = {
        'protocol': relayProtocolVersion,
        'roomId': 'abcdefghijklmnopqrstuvwx',
        'hostSecret': 'private-secret-value-at-least-twenty-chars',
        'joinUrl': 'https://relay.example/r/abcdefghijklmnopqrstuvwx/',
        'expiresAt': 4102444800000,
      };

      expect(
        () => OnlineRelaySession.fromJson({...valid, 'roomId': 'short'}),
        throwsFormatException,
      );
      expect(
        () => OnlineRelaySession.fromJson({...valid, 'hostSecret': 'short'}),
        throwsFormatException,
      );
      expect(
        () => OnlineRelaySession.fromJson({
          ...valid,
          'joinUrl': 'https://relay.example/r/different-room-identifier/',
        }),
        throwsFormatException,
      );
    });
  });

  group('OnlineRelayBridge', () {
    late ServerController controller;
    late List<Map<String, dynamic>> sent;
    late OnlineRelayBridge bridge;
    late ({String token, String playerId}) host;

    setUp(() {
      controller = ServerController(rng: Random(44));
      host = controller.resolveSession('Organizer', null);
      controller.createTournament(
        name: 'Online Cup',
        hostPlayerId: host.playerId,
      );
      sent = [];
      bridge = OnlineRelayBridge(controller: controller, send: sent.add);
    });

    test('auth changes the connection to a personalized snapshot', () async {
      final alice = controller.resolveSession('Alice', null);

      await bridge.handle({'type': 'player.open', 'clientId': 'client_1'});
      expect(bridge.playerCount, 1);
      expect(_payload(sent.last)['you'], isNull);

      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_1',
        'payload': {'type': 'auth', 'token': alice.token},
      });

      final snapshot = _payload(sent.last);
      expect(snapshot['you'], isA<Map>());
      expect((snapshot['you'] as Map)['nickname'], 'Alice');
      expect((snapshot['you'] as Map)['playerId'], alice.playerId);
    });

    test('dispatches allowed commands and blocks host endpoints', () async {
      await bridge.handle({'type': 'player.open', 'clientId': 'client_2'});
      sent.clear();

      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_2',
        'payload': {
          'type': 'command',
          'requestId': 'join-1',
          'path': '/api/join',
          'body': {'nickname': 'Bob', 'code': controller.joinCode},
        },
      });

      final joined = _response(sent, 'join-1');
      expect(joined['status'], 200);
      final playerToken = (joined['body'] as Map)['token'] as String;

      // A successful join binds the virtual socket immediately, so the first
      // authenticated command does not depend on a second auth round-trip.
      sent.clear();
      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_2',
        'payload': {
          'type': 'command',
          'requestId': 'deck-1',
          'path': '/api/deck',
          'body': {'token': playerToken, 'name': 'Burn'},
        },
      });
      expect(_response(sent, 'deck-1')['status'], 200);

      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_2',
        'payload': {
          'type': 'command',
          'requestId': 'admin-1',
          'path': '/api/host/start',
          'body': {'token': host.token},
        },
      });

      final blocked = _response(sent, 'admin-1');
      expect(blocked['status'], 403);
      expect((blocked['body'] as Map)['error'], 'Command not allowed.');
      expect(controller.engine!.rounds, isEmpty);
    });

    test(
      'reports an oversized snapshot instead of silently dropping it',
      () async {
        bridge = OnlineRelayBridge(
          controller: controller,
          send: sent.add,
          maxFrameBytes: 256,
        );

        await bridge.handle({
          'type': 'player.open',
          'clientId': 'client_large',
        });

        expect(_payload(sent.last), {
          'type': 'relay.error',
          'message': 'The tournament state is too large to deliver.',
        });
      },
    );

    test('binds non-join commands to the virtual connection token', () async {
      final alice = controller.resolveSession('Alice', null);
      final mallory = controller.resolveSession('Mallory', null);
      await bridge.handle({'type': 'player.open', 'clientId': 'client_auth'});
      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_auth',
        'payload': {'type': 'auth', 'token': alice.token},
      });
      sent.clear();

      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_auth',
        'payload': {
          'type': 'command',
          'requestId': 'stolen-token',
          'path': '/api/deck',
          'body': {'token': mallory.token, 'name': 'Stolen session'},
        },
      });

      expect(_response(sent, 'stolen-token')['status'], 401);
      expect(controller.decks, isEmpty);
    });

    test(
      'rejects malformed traffic and removes all player connections',
      () async {
        await bridge.handle({'type': 'player.open', 'clientId': '../unsafe'});
        await bridge.handle({'type': 'player.open', 'clientId': 'safe-client'});
        expect(bridge.playerCount, 1);

        sent.clear();
        await bridge.handle({
          'type': 'player.message',
          'clientId': 'safe-client',
          'payload': {
            'type': 'command',
            'requestId': 'query-smuggle',
            'path': '/api/join?admin=true',
            'body': {'nickname': 'Mallory', 'code': controller.joinCode},
          },
        });
        expect(_response(sent, 'query-smuggle')['status'], 403);
        expect(
          controller.players.values.where((p) => p.nickname == 'Mallory'),
          isEmpty,
        );

        bridge.disconnectAll();
        expect(bridge.playerCount, 0);
        final countAfterDisconnect = sent.length;
        controller.persistAndNotify();
        expect(sent, hasLength(countAfterDisconnect));
      },
    );

    test('bounds command bodies before invoking the Shelf handler', () async {
      bridge = OnlineRelayBridge(
        controller: controller,
        send: sent.add,
        maxFrameBytes: 2048,
        maxCommandBodyBytes: 32,
      );
      await bridge.handle({'type': 'player.open', 'clientId': 'client_3'});
      sent.clear();

      await bridge.handle({
        'type': 'player.message',
        'clientId': 'client_3',
        'payload': {
          'type': 'command',
          'requestId': 'large-1',
          'path': '/api/join',
          'body': {'nickname': 'A' * 100, 'code': controller.joinCode},
        },
      });

      expect(_response(sent, 'large-1')['status'], 413);
    });
  });

  group('OnlineRelayClient', () {
    test('rejects an expired room before opening a socket', () async {
      var connectorCalled = false;
      final client = OnlineRelayClient(
        controller: ServerController(),
        baseUrl: Uri.parse('https://relay.example'),
        channelConnector: (_) {
          connectorCalled = true;
          throw StateError('The connector must not run.');
        },
      );
      const expired = OnlineRelaySession(
        roomId: 'abcdefghijklmnopqrstuvwx',
        hostSecret: 'private-secret-value-at-least-twenty-chars',
        joinUrl: 'https://relay.example/r/abcdefghijklmnopqrstuvwx/',
        expiresAtEpochMs: 1577836800000,
      );

      await expectLater(client.start(expired), throwsA(isA<RelayException>()));
      expect(connectorCalled, isFalse);
      await client.dispose();
    });

    test('only a rejected key asks the organizer for a provisioning key', () {
      expect(
        relayNeedsProvisionKey(
          const RelayException('needs a key', statusCode: 401),
        ),
        isTrue,
      );
      // Everything else is retried or reported, never answered with a prompt.
      expect(
        relayNeedsProvisionKey(
          const RelayException('rate limited', statusCode: 429),
        ),
        isFalse,
      );
      expect(relayNeedsProvisionKey(const RelayException('offline')), isFalse);
      expect(relayNeedsProvisionKey(StateError('unrelated')), isFalse);
      expect(relayNeedsProvisionKey(null), isFalse);
    });
  });
}

Map<String, dynamic> _payload(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload'] as Map);

Map<String, dynamic> _response(
  List<Map<String, dynamic>> sent,
  String requestId,
) => _payload(
  sent.lastWhere(
    (envelope) =>
        envelope['type'] == 'player.send' &&
        (envelope['payload'] as Map)['requestId'] == requestId,
  ),
);
