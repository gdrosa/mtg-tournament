/// The embedded LAN server: REST commands + WebSocket snapshots + static PWA.
///
/// PURE DART — no Flutter imports — so the exact same handler runs inside the
/// host app's isolate and standalone via `dart run bin/dev_server.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../shared/tournament_engine.dart';
import 'controller.dart';

Response _json(Object data, {int status = 200}) => Response(
  status,
  body: jsonEncode(data),
  headers: {'content-type': 'application/json'},
);

Future<Map<String, dynamic>> _body(Request r) async {
  final s = await r.readAsString();
  if (s.isEmpty) return {};
  return (jsonDecode(s) as Map).cast<String, dynamic>();
}

/// Runs [fn] and maps an [EngineError] to a 400 JSON error.
Response _guard(Object Function() fn) {
  try {
    return _json(fn());
  } on EngineError catch (e) {
    return _json({'error': e.message}, status: 400);
  } catch (e) {
    return _json({'error': e.toString()}, status: 500);
  }
}

/// Build the full request handler (REST + WS), falling back to [staticHandler]
/// (the PWA) for any other path. When [imageDirPath] is given, cached Scryfall
/// card images under it are served at `GET /cards/img/<id>` (offline, LAN-only).
Handler buildHandler(
  ServerController c, {
  Handler? staticHandler,
  String? imageDirPath,
}) {
  final api = Router();

  // ---- cached card images (served from the host's local cache, no internet) ----
  if (imageDirPath != null) {
    api.get('/cards/img/<id>', (Request r, String id) async {
      // guard against path traversal — ids are Scryfall uuids only
      if (id.contains('/') || id.contains('\\') || id.contains('..')) {
        return Response.notFound('bad id');
      }
      final f = File('$imageDirPath${Platform.pathSeparator}$id.jpg');
      if (!await f.exists()) return Response.notFound('no image');
      return Response.ok(
        f.openRead(),
        headers: {
          'content-type': 'image/jpeg',
          'cache-control': 'public, max-age=31536000, immutable',
        },
      );
    });
  }

  // ---- identity & decks ----
  api.post('/api/join', (Request r) async {
    final b = await _body(r);
    final nickname = (b['nickname'] as String?)?.trim() ?? '';
    if (nickname.isEmpty) {
      return _json({'error': 'Nickname required.'}, status: 400);
    }
    final code = (b['code'] as String?)?.trim().toUpperCase();
    if (c.joinCode == null) {
      return _json({'error': 'No active tournament.'}, status: 400);
    }
    if (code != c.joinCode) {
      return _json({'error': 'Wrong event code.'}, status: 400);
    }
    final s = c.resolveSession(nickname, b['token'] as String?);
    return _json({'token': s.token, 'playerId': s.playerId});
  });

  api.post('/api/deck', (Request r) async {
    final b = await _body(r);
    final pid = c.playerIdForToken(b['token'] as String?);
    if (pid == null) return _json({'error': 'Not authenticated.'}, status: 401);
    // Never trust a client-supplied id: only honour it to edit a deck the caller
    // already owns, otherwise mint a fresh server uuid. This keeps deck ids to
    // server-generated uuids, so they can never carry an injection payload that
    // a client later reflects into the DOM.
    final supplied = b['deckId'] as String?;
    final deckId = (supplied != null && c.decks[supplied]?.ownerId == pid)
        ? supplied
        : null;
    return _guard(() {
      final d = c.saveDeck(
        ownerId: pid,
        deckId: deckId,
        name: (b['name'] as String?) ?? 'Unnamed',
        mainboard: (b['mainboard'] as String?) ?? '',
        sideboard: (b['sideboard'] as String?) ?? '',
      );
      return {'deckId': d.id};
    });
  });

  api.post('/api/enter', (Request r) async {
    final b = await _body(r);
    final pid = c.playerIdForToken(b['token'] as String?);
    if (pid == null) return _json({'error': 'Not authenticated.'}, status: 401);
    return _guard(() {
      c.joinTournament(playerId: pid, deckId: b['deckId'] as String);
      return {'ok': true};
    });
  });

  // ---- player commands ----
  api.post('/api/result', (Request r) async {
    final b = await _body(r);
    final pid = c.playerIdForToken(b['token'] as String?);
    if (pid == null) return _json({'error': 'Not authenticated.'}, status: 401);
    return _guard(() {
      c.submitResult(
        playerId: pid,
        matchId: b['matchId'] as String,
        mineWon: (b['mineWon'] as num).toInt(),
        oppWon: (b['oppWon'] as num).toInt(),
        draws: (b['draws'] as num?)?.toInt() ?? 0,
      );
      return {'ok': true};
    });
  });

  api.post('/api/infraction', (Request r) async {
    final b = await _body(r);
    final pid = c.playerIdForToken(b['token'] as String?);
    if (pid == null) return _json({'error': 'Not authenticated.'}, status: 401);
    return _guard(() {
      c.confirmInfraction(
        playerId: pid,
        matchId: b['matchId'] as String,
        ok: b['ok'] == true,
      );
      return {'ok': true};
    });
  });

  // ---- host / admin commands (token must be the host) ----
  Response requireHost(String? token, Object Function() fn) {
    final pid = c.playerIdForToken(token);
    if (pid == null || pid != c.hostPlayerId) {
      return _json({'error': 'Host only.'}, status: 403);
    }
    return _guard(fn);
  }

  api.post('/api/host/create', (Request r) async {
    final b = await _body(r);
    final nickname = (b['nickname'] as String?)?.trim() ?? '';
    if (nickname.isEmpty) {
      return _json({'error': 'Nickname required.'}, status: 400);
    }
    // First-event bootstrap is open (there is no host yet to authorize against),
    // but once an event exists, only the existing host/owner token may replace it
    // — otherwise any LAN client could wipe the running tournament and seize host.
    if (c.engine != null) {
      final existing = c.playerIdForToken(b['token'] as String?);
      if (existing == null ||
          (existing != c.hostPlayerId && existing != c.ownerPlayerId)) {
        return _json({'error': 'An event is already running.'}, status: 403);
      }
    }
    // Bootstraps the host's durable identity and the tournament together.
    final s = c.resolveSession(nickname, b['token'] as String?);
    return _guard(() {
      final code = c.createTournament(
        name: (b['name'] as String?) ?? 'Tournament',
        hostPlayerId: s.playerId,
      );
      return {'token': s.token, 'playerId': s.playerId, 'joinCode': code};
    });
  });

  api.post('/api/host/start', (Request r) async {
    final b = await _body(r);
    return requireHost(b['token'] as String?, () {
      c.startTournament();
      return {'ok': true};
    });
  });

  api.post('/api/host/advance', (Request r) async {
    final b = await _body(r);
    return requireHost(b['token'] as String?, () {
      c.advanceRound();
      return {'ok': true};
    });
  });

  api.post('/api/host/resolve', (Request r) async {
    final b = await _body(r);
    return requireHost(b['token'] as String?, () {
      c.hostResolve(
        b['matchId'] as String,
        (b['p1Wins'] as num).toInt(),
        (b['p2Wins'] as num).toInt(),
        note: b['note'] as String?,
      );
      return {'ok': true};
    });
  });

  api.post('/api/host/drop', (Request r) async {
    final b = await _body(r);
    return requireHost(b['token'] as String?, () {
      c.dropPlayer(b['playerId'] as String);
      return {'ok': true};
    });
  });

  // ---- realtime snapshots ----
  api.get(
    '/ws',
    webSocketHandler((WebSocketChannel channel, String? _) {
      final conn = Connection((msg) {
        try {
          channel.sink.add(msg);
        } catch (_) {
          /* peer gone */
        }
      });
      c.addConnection(conn);
      channel.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map;
            if (msg['type'] == 'auth') {
              conn.token = msg['token'] as String?;
              conn.send(c.snapshotJsonFor(conn.token)); // re-send as the player
            }
          } catch (_) {
            /* ignore malformed */
          }
        },
        onDone: () => c.removeConnection(conn),
        onError: (_) => c.removeConnection(conn),
        cancelOnError: true,
      );
    }, pingInterval: const Duration(seconds: 30)),
  );

  // health check + on-demand snapshot (handy for tests; WS is the live channel)
  api.get(
    '/api/health',
    (Request r) => _json({'ok': true, 'code': c.joinCode}),
  );
  api.get(
    '/api/snapshot',
    (Request r) => Response.ok(
      c.snapshotJsonFor(r.url.queryParameters['token']),
      headers: {'content-type': 'application/json'},
    ),
  );

  if (staticHandler == null) return api.call;
  return Cascade().add(api.call).add(staticHandler).handler;
}

/// Bind and serve on [port] across all LAN interfaces (0.0.0.0).
Future<HttpServer> serveController(
  ServerController c, {
  int port = 8080,
  Handler? staticHandler,
  String? imageDirPath,
  bool log = false,
}) {
  var pipeline = const Pipeline();
  if (log) pipeline = pipeline.addMiddleware(logRequests());
  final handler = pipeline.addHandler(
    buildHandler(c, staticHandler: staticHandler, imageDirPath: imageDirPath),
  );
  return io.serve(handler, InternetAddress.anyIPv4, port);
}

/// The host's LAN IPv4 (for the join URL/QR), or null if not on a network.
Future<String?> lanIpv4() async {
  final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  for (final i in ifaces) {
    for (final a in i.addresses) {
      if (!a.isLoopback) return a.address;
    }
  }
  return null;
}
