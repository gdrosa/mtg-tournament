/// End-to-end compatibility check for a locally running Cloudflare relay.
///
/// Start `npm run dev` in `cloudflare/`, then run:
///
///   dart run tool/relay_smoke.dart http://127.0.0.1:8787 [provisioning-key]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mtg_tourney/host/online_relay.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/shared/hosting.dart';
import 'package:web_socket_channel/io.dart';

Future<void> main(List<String> arguments) async {
  final baseUrl = Uri.parse(
    arguments.isEmpty ? 'http://127.0.0.1:8787' : arguments.first,
  );
  final provisionKey = arguments.length > 1 ? arguments[1] : null;
  final controller = ServerController();
  final host = controller.resolveSession('Smoke-test host', null);
  controller.createTournament(
    name: 'Relay smoke test',
    hostPlayerId: host.playerId,
    mode: HostingMode.online,
  );

  final relay = OnlineRelayClient(
    controller: controller,
    baseUrl: baseUrl,
    provisionKey: provisionKey,
    store: MemoryOnlineRelaySessionStore(),
  );
  IOWebSocketChannel? player;
  StreamIterator<dynamic>? messages;
  try {
    final provisioned = await relay.provision();
    await relay.start(provisioned.copyWith(eventId: controller.engine!.id));

    final playerUri = baseUrl.replace(
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
      path: '/v1/rooms/${provisioned.roomId}/player',
      query: null,
      fragment: null,
    );
    player = IOWebSocketChannel.connect(
      playerUri,
      headers: {'Origin': baseUrl.origin},
    );
    await player.ready;
    messages = StreamIterator<dynamic>(player.stream);

    await _next(messages, (m) => m['type'] == 'relay.ready');
    await _next(messages, (m) => m['phase'] == 'lobby');

    player.sink.add(
      jsonEncode({
        'type': 'command',
        'requestId': 'smoke-join',
        'path': '/api/join',
        'body': {'nickname': 'Smoke-test player', 'code': controller.joinCode},
      }),
    );
    final response = await _next(
      messages,
      (m) => m['type'] == 'response' && m['requestId'] == 'smoke-join',
    );
    if (response['status'] != 200 || response['body'] is! Map) {
      throw StateError('Join command failed: $response');
    }
    final token = (response['body'] as Map)['token'];
    if (token is! String || token.isEmpty) {
      throw StateError('Join response did not contain a token.');
    }

    player.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    final personalized = await _next(
      messages,
      (m) => (m['you'] as Map?)?['nickname'] == 'Smoke-test player',
    );
    if ((personalized['you'] as Map?)?['playerId'] == null) {
      throw StateError('Personalized snapshot was incomplete.');
    }

    stdout.writeln('Relay smoke test passed for ${provisioned.joinUrl}');
  } finally {
    await messages?.cancel();
    await player?.sink.close();
    await relay.stop(closeRoom: true);
    await relay.dispose();
  }
}

Future<Map<String, dynamic>> _next(
  StreamIterator<dynamic> messages,
  bool Function(Map<String, dynamic>) matches,
) async {
  while (await messages.moveNext().timeout(const Duration(seconds: 10))) {
    final raw = messages.current;
    if (raw is! String) continue;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) continue;
    final message = Map<String, dynamic>.from(decoded);
    if (matches(message)) return message;
  }
  throw StateError('Relay WebSocket closed before the expected message.');
}
