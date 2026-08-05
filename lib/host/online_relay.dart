/// Outbound online transport for an organizer-hosted tournament.
///
/// The phone remains authoritative: a public relay only multiplexes browser
/// clients onto this WebSocket. Player commands are dispatched through the
/// same Shelf handler used by the LAN server, so both hosting modes share one
/// validation and tournament implementation.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../server/controller.dart';
import '../server/server.dart';

const int relayProtocolVersion = 1;
const int _defaultMaxFrameBytes = 512 * 1024;
const int _defaultMaxCommandBodyBytes = 128 * 1024;

enum RelayConnectionState { stopped, connecting, connected, reconnecting }

class RelayException implements Exception {
  final String message;
  final int? statusCode;

  const RelayException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'RelayException: $message'
      : 'RelayException ($statusCode): $message';
}

/// Credentials and public URL for one relay room.
///
/// [hostSecret] must remain on the organizer's device. Only [joinUrl] is safe
/// to put in a QR code or send to participants.
class OnlineRelaySession {
  final String roomId;
  final String hostSecret;
  final String joinUrl;
  final int expiresAtEpochMs;
  final String? eventId;

  const OnlineRelaySession({
    required this.roomId,
    required this.hostSecret,
    required this.joinUrl,
    required this.expiresAtEpochMs,
    this.eventId,
  });

  factory OnlineRelaySession.fromJson(Map<Object?, Object?> json) {
    if (json['protocol'] != relayProtocolVersion) {
      throw const FormatException('Unsupported relay protocol.');
    }
    final roomId = json['roomId'];
    final hostSecret = json['hostSecret'];
    final joinUrl = json['joinUrl'];
    final expiresAt = json['expiresAt'];
    final eventId = json['eventId'];
    if (roomId is! String || !_validRoomId(roomId)) {
      throw const FormatException('Invalid relay room id.');
    }
    if (hostSecret is! String ||
        hostSecret.length < 20 ||
        hostSecret.length > 256) {
      throw const FormatException('Invalid relay host secret.');
    }
    if (joinUrl is! String || !_validJoinUrl(joinUrl, roomId)) {
      throw const FormatException('Invalid relay join URL.');
    }
    if (expiresAt is! int || expiresAt <= 0) {
      throw const FormatException('Invalid relay expiry.');
    }
    if (eventId != null &&
        (eventId is! String || eventId.isEmpty || eventId.length > 128)) {
      throw const FormatException('Invalid relay event id.');
    }
    return OnlineRelaySession(
      roomId: roomId,
      hostSecret: hostSecret,
      joinUrl: joinUrl,
      expiresAtEpochMs: expiresAt,
      eventId: eventId as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'protocol': relayProtocolVersion,
    'roomId': roomId,
    'hostSecret': hostSecret,
    'joinUrl': joinUrl,
    'expiresAt': expiresAtEpochMs,
    if (eventId != null) 'eventId': eventId,
  };

  OnlineRelaySession copyWith({String? eventId}) => OnlineRelaySession(
    roomId: roomId,
    hostSecret: hostSecret,
    joinUrl: joinUrl,
    expiresAtEpochMs: expiresAtEpochMs,
    eventId: eventId ?? this.eventId,
  );

  /// Treat a room that is about to expire as stale so restart/recovery has
  /// enough time to provision and publish a replacement join link.
  bool isExpired({
    DateTime? now,
    Duration margin = const Duration(minutes: 1),
  }) {
    final instant = now ?? DateTime.now();
    return instant.add(margin).millisecondsSinceEpoch >= expiresAtEpochMs;
  }

  bool belongsTo(Uri relayBaseUrl) =>
      _sameOrigin(Uri.parse(joinUrl), relayBaseUrl);
}

abstract class OnlineRelaySessionStore {
  OnlineRelaySession? load();

  void save(OnlineRelaySession session);

  void clear();
}

/// Small local store for reconnecting the active room after an app restart.
class FileOnlineRelaySessionStore implements OnlineRelaySessionStore {
  final String path;

  const FileOnlineRelaySessionStore(this.path);

  @override
  OnlineRelaySession? load() {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return OnlineRelaySession.fromJson(decoded);
    } catch (_) {
      // A partial or stale transport file must not prevent the app from opening.
      return null;
    }
  }

  @override
  void save(OnlineRelaySession session) {
    final destination = File(path);
    destination.parent.createSync(recursive: true);
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(jsonEncode(session.toJson()), flush: true);
    // renameSync does not replace an existing file consistently on Windows.
    if (destination.existsSync()) destination.deleteSync();
    temporary.renameSync(path);
  }

  @override
  void clear() {
    final destination = File(path);
    if (destination.existsSync()) destination.deleteSync();
    final temporary = File('$path.tmp');
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

class MemoryOnlineRelaySessionStore implements OnlineRelaySessionStore {
  OnlineRelaySession? value;

  @override
  OnlineRelaySession? load() => value;

  @override
  void save(OnlineRelaySession session) => value = session;

  @override
  void clear() => value = null;
}

typedef RelayEnvelopeSink = void Function(Map<String, dynamic> envelope);

class RelayRequestCache {
  static const int _maxEntries = 128;
  final LinkedHashMap<String, _RelayCachedResponse> _entries =
      LinkedHashMap<String, _RelayCachedResponse>();

  _RelayCachedResponse? _lookup(String requestId) => _entries[requestId];

  void _store(String requestId, _RelayCachedResponse response) {
    _entries.remove(requestId);
    _entries[requestId] = response;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}

class _RelayCachedResponse {
  final String path;
  final int status;
  final Object? body;

  const _RelayCachedResponse({
    required this.path,
    required this.status,
    required this.body,
  });
}

/// Maps relay player IDs to the controller's existing tailored [Connection]s.
///
/// This class contains no network code, which keeps the security boundary easy
/// to exercise in unit tests.
class OnlineRelayBridge {
  static const allowedCommandPaths = <String>{
    '/api/join',
    '/api/deck',
    '/api/enter',
    '/api/result',
    '/api/infraction',
  };

  final ServerController controller;
  final RelayEnvelopeSink send;
  final Handler _apiHandler;
  final RelayRequestCache _requestCache;
  final int maxFrameBytes;
  final int maxCommandBodyBytes;
  final Map<String, Connection> _players = {};

  OnlineRelayBridge({
    required this.controller,
    required this.send,
    Handler? apiHandler,
    RelayRequestCache? requestCache,
    this.maxFrameBytes = _defaultMaxFrameBytes,
    this.maxCommandBodyBytes = _defaultMaxCommandBodyBytes,
  }) : _apiHandler = apiHandler ?? buildHandler(controller),
       _requestCache = requestCache ?? RelayRequestCache();

  int get playerCount => _players.length;

  /// Handle one decoded relay envelope. Malformed/unrecognized relay traffic
  /// is ignored; a malformed command with a usable request id gets a bounded
  /// JSON error response instead.
  Future<void> handle(Object? envelope) async {
    if (envelope is! Map) return;
    if (!_fitsJson(envelope, maxFrameBytes)) return;

    final type = envelope['type'];
    final clientId = envelope['clientId'];
    if (type is! String || clientId is! String || !_validOpaqueId(clientId)) {
      return;
    }

    switch (type) {
      case 'player.open':
        _open(clientId);
      case 'player.message':
        await _message(clientId, envelope['payload']);
      case 'player.close':
        _close(clientId);
    }
  }

  void _open(String clientId) {
    _close(clientId);
    late final Connection connection;
    connection = Connection((snapshot) {
      if (!identical(_players[clientId], connection)) return;
      try {
        final decoded = jsonDecode(snapshot);
        if (decoded is! Map) return;
        _sendToPlayer(clientId, Map<String, dynamic>.from(decoded));
      } catch (_) {
        // Controller snapshots are expected to be JSON; never take the host
        // connection down if a future snapshot format is malformed.
      }
    });
    _players[clientId] = connection;
    controller.addConnection(connection);
  }

  Future<void> _message(String clientId, Object? payload) async {
    final connection = _players[clientId];
    if (connection == null || payload is! Map) return;
    if (!_fitsJson(payload, maxFrameBytes)) return;

    final type = payload['type'];
    if (type == 'auth') {
      final token = payload['token'];
      if (token != null && (token is! String || token.length > 1024)) return;
      final nextToken = token as String?;
      // `player.open` already emitted the anonymous snapshot. Repeated auth
      // frames for an unchanged token must not amplify into full snapshots.
      if (connection.token == nextToken) return;
      connection.token = nextToken;
      connection.send(controller.snapshotJsonFor(connection.token));
      return;
    }

    // `request` was used by an early relay prototype; retaining it as an alias
    // makes rolling upgrades harmless. Browser clients send `command`.
    if (type != 'command' && type != 'request') return;
    await _command(clientId, connection, payload);
  }

  Future<void> _command(
    String clientId,
    Connection connection,
    Map payload,
  ) async {
    final requestId = payload['requestId'];
    if (requestId is! String || !_validRequestId(requestId)) return;

    final method = payload['method'];
    if (method != null && method != 'POST') {
      _respond(clientId, connection, requestId, 405, {
        'error': 'Only POST commands are supported.',
      });
      return;
    }

    final path = payload['path'];
    if (path is! String || !allowedCommandPaths.contains(path)) {
      _respond(clientId, connection, requestId, 403, {
        'error': 'Command not allowed.',
      });
      return;
    }

    final cached = _requestCache._lookup(requestId);
    if (cached != null) {
      if (cached.path != path) {
        _respond(clientId, connection, requestId, 409, {
          'error': 'A request id cannot be reused for another command.',
        });
        return;
      }
      _respond(clientId, connection, requestId, cached.status, cached.body);
      _bindJoinedSession(connection, path, cached.status, cached.body);
      return;
    }

    final rawBody = payload['body'];
    if (rawBody is! Map) {
      _respond(clientId, connection, requestId, 400, {
        'error': 'A JSON object body is required.',
      });
      return;
    }
    final body = Map<String, dynamic>.from(rawBody);

    // The browser's authenticated virtual socket and command body must agree.
    // Otherwise one player who learns another bearer token could use it through
    // an unrelated relay connection. `/api/join` is the only bootstrap command
    // and is followed by an `auth` frame carrying the returned session token.
    if (path != '/api/join') {
      final bodyToken = body['token'];
      if (connection.token == null ||
          bodyToken is! String ||
          bodyToken != connection.token) {
        _respond(clientId, connection, requestId, 401, {
          'error': 'Connection authentication does not match the command.',
        });
        return;
      }
    } else if (connection.token != null) {
      // Once this virtual socket owns a session, joining again can only update
      // that same player; it cannot mint an unlimited series of identities.
      body['token'] = connection.token;
    }

    String encodedBody;
    try {
      encodedBody = jsonEncode(body);
    } catch (_) {
      _respond(clientId, connection, requestId, 400, {
        'error': 'Invalid JSON body.',
      });
      return;
    }
    if (utf8.encode(encodedBody).length > maxCommandBodyBytes) {
      _respond(clientId, connection, requestId, 413, {
        'error': 'Command body is too large.',
      });
      return;
    }

    try {
      final response = await _apiHandler(
        Request(
          'POST',
          Uri.parse('http://online-relay.invalid$path'),
          body: encodedBody,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final responseBody = await _readResponse(response, maxFrameBytes);
      if (response.statusCode < 500 &&
          _fitsJson(responseBody, _defaultMaxCommandBodyBytes)) {
        _requestCache._store(
          requestId,
          _RelayCachedResponse(
            path: path,
            status: response.statusCode,
            body: responseBody,
          ),
        );
      }
      _respond(
        clientId,
        connection,
        requestId,
        response.statusCode,
        responseBody,
      );
      _bindJoinedSession(connection, path, response.statusCode, responseBody);
    } on _ResponseTooLarge {
      _respond(clientId, connection, requestId, 502, {
        'error': 'Host response is too large.',
      });
    } catch (_) {
      _respond(clientId, connection, requestId, 500, {
        'error': 'Host could not process the command.',
      });
    }
  }

  void _bindJoinedSession(
    Connection connection,
    String path,
    int status,
    Object? body,
  ) {
    if (path != '/api/join' || status < 200 || status >= 300 || body is! Map) {
      return;
    }
    final token = body['token'];
    if (token is! String || token.isEmpty) return;
    connection.token = token;
    connection.send(controller.snapshotJsonFor(connection.token));
  }

  void _respond(
    String clientId,
    Connection connection,
    String requestId,
    int status,
    Object? body,
  ) {
    if (!identical(_players[clientId], connection)) return;
    _sendToPlayer(clientId, {
      'type': 'response',
      'requestId': requestId,
      'status': status,
      'body': body,
    });
  }

  void _sendToPlayer(String clientId, Map<String, dynamic> payload) {
    final envelope = <String, dynamic>{
      'type': 'player.send',
      'clientId': clientId,
      'payload': payload,
    };
    if (!_fitsJson(envelope, maxFrameBytes)) {
      final fallback = <String, dynamic>{
        'type': 'player.send',
        'clientId': clientId,
        'payload': const {
          'type': 'relay.error',
          'message': 'The tournament state is too large to deliver.',
        },
      };
      try {
        send(fallback);
      } catch (_) {
        // The socket may disappear during a synchronous controller broadcast.
      }
      return;
    }
    try {
      send(envelope);
    } catch (_) {
      // A socket may disappear during a synchronous controller broadcast.
    }
  }

  void _close(String clientId) {
    final connection = _players.remove(clientId);
    if (connection != null) controller.removeConnection(connection);
  }

  void disconnectAll() {
    final connections = _players.values.toList(growable: false);
    _players.clear();
    for (final connection in connections) {
      controller.removeConnection(connection);
    }
  }
}

typedef RelayChannelConnector = WebSocketChannel Function(Uri uri);

/// Owns the organizer's single outbound relay WebSocket and reconnect loop.
class OnlineRelayClient {
  final ServerController controller;
  final Uri baseUrl;

  /// Provisioning key for relays that restrict who may create rooms. Not a
  /// secret in any real sense — it ships inside the APK — but it is revocable,
  /// so an abused build can be cut off without moving the relay.
  final String? provisionKey;
  final OnlineRelaySessionStore? store;
  final Duration connectTimeout;
  final Duration handshakeTimeout;
  final Duration minReconnectDelay;
  final Duration maxReconnectDelay;
  final Random _random;
  final RelayChannelConnector _channelConnector;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;

  final StreamController<RelayConnectionState> _stateController =
      StreamController<RelayConnectionState>.broadcast(sync: true);
  final RelayRequestCache _requestCache = RelayRequestCache();

  RelayConnectionState _state = RelayConnectionState.stopped;
  OnlineRelaySession? _session;
  Object? _lastError;
  bool _enabled = false;
  bool _disposed = false;
  int _run = 0;
  int _socketSerial = 0;
  int? _activeSocketSerial;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  OnlineRelayBridge? _bridge;
  Completer<void>? _firstReady;
  Completer<void>? _handshake;
  Future<void> _messageQueue = Future<void>.value();

  OnlineRelayClient({
    required this.controller,
    required this.baseUrl,
    this.provisionKey,
    this.store,
    this.connectTimeout = const Duration(seconds: 12),
    this.handshakeTimeout = const Duration(seconds: 8),
    this.minReconnectDelay = const Duration(seconds: 1),
    this.maxReconnectDelay = const Duration(seconds: 30),
    Random? random,
    RelayChannelConnector? channelConnector,
    HttpClient? httpClient,
  }) : _random = random ?? Random.secure(),
       _channelConnector =
           channelConnector ??
           ((uri) => IOWebSocketChannel.connect(
             uri,
             pingInterval: const Duration(seconds: 25),
             connectTimeout: connectTimeout,
           )),
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    if (baseUrl.scheme != 'https' && baseUrl.scheme != 'http') {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Must use HTTP or HTTPS.');
    }
    if (baseUrl.host.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'Must include a host.');
    }
    if (minReconnectDelay.isNegative || maxReconnectDelay.isNegative) {
      throw ArgumentError('Reconnect delays cannot be negative.');
    }
  }

  RelayConnectionState get state => _state;
  Stream<RelayConnectionState> get stateChanges => _stateController.stream;
  OnlineRelaySession? get session => _session;
  String? get joinUrl => _session?.joinUrl;
  Object? get lastError => _lastError;
  bool get isEnabled => _enabled;

  OnlineRelaySession? loadSavedSession() => store?.load();

  void clearSavedSession() => store?.clear();

  /// Allocate a fresh public room and persist its organizer credentials.
  Future<OnlineRelaySession> provision() async {
    _checkUsable();
    final uri = _endpoint('v1', 'rooms');
    HttpClientRequest request;
    try {
      request = await _httpClient.postUrl(uri).timeout(connectTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('x-mtg-relay-protocol', '$relayProtocolVersion');
      final key = provisionKey;
      if (key != null && key.isNotEmpty) {
        request.headers.set('x-mtg-relay-key', key);
      }
      request.write('{}');
      final response = await request.close().timeout(connectTimeout);
      final text = await _readHttpResponse(response, _defaultMaxFrameBytes);
      Object? decoded;
      try {
        decoded = text.isEmpty ? null : jsonDecode(text);
      } catch (_) {
        throw RelayException(
          'The relay returned an invalid response.',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail =
            _relayErrorMessage(decoded) ?? 'The relay could not create a room.';
        throw RelayException(detail, statusCode: response.statusCode);
      }
      if (decoded is! Map) {
        throw const RelayException('The relay returned an invalid room.');
      }
      final created = OnlineRelaySession.fromJson(decoded);
      if (!_sameOrigin(Uri.parse(created.joinUrl), baseUrl)) {
        throw const RelayException(
          'The relay returned a join URL for a different origin.',
        );
      }
      _session = created;
      _requestCache.clear();
      store?.save(created);
      return created;
    } on RelayException {
      rethrow;
    } on TimeoutException {
      throw const RelayException('The relay timed out while creating a room.');
    } on SocketException {
      throw const RelayException('The relay is unreachable.');
    } on FormatException {
      throw const RelayException('The relay returned an invalid room.');
    }
  }

  /// Start hosting [relaySession], or resume the locally persisted session.
  ///
  /// The returned future completes at the first `host.ready`. If that first
  /// attempt fails it completes with an error, while reconnects continue until
  /// [stop] is called.
  Future<void> start([OnlineRelaySession? relaySession]) async {
    _checkUsable();
    if (_enabled) await stop();
    final selected = relaySession ?? store?.load() ?? _session;
    if (selected == null) {
      throw const RelayException('No online relay room has been provisioned.');
    }
    if (!_sameOrigin(Uri.parse(selected.joinUrl), baseUrl)) {
      throw const RelayException(
        'The saved room belongs to a different relay origin.',
      );
    }
    if (selected.isExpired()) {
      throw const RelayException('The saved relay room has expired.');
    }
    _session = selected;
    store?.save(selected);
    _enabled = true;
    _lastError = null;
    _reconnectAttempt = 0;
    _run++;
    _firstReady = Completer<void>();
    _setState(RelayConnectionState.connecting);
    unawaited(_connect(_run));
    await _firstReady!.future;
  }

  Future<OnlineRelaySession> provisionAndStart() async {
    final created = await provision();
    await start(created);
    return created;
  }

  /// Stop reconnecting and close the current host socket. With [closeRoom],
  /// also ask the relay to invalidate the room and remove local credentials.
  Future<void> stop({bool closeRoom = false}) async {
    if (_disposed && !_enabled) return;
    _enabled = false;
    _run++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final channel = _channel;
    if (closeRoom && channel != null) {
      try {
        channel.sink.add(jsonEncode(const {'type': 'room.close'}));
      } catch (_) {
        // The socket may already be gone; local cleanup still proceeds.
      }
    }
    _activeSocketSerial = null;
    _channel = null;
    _handshake = null;
    final subscription = _subscription;
    _subscription = null;
    _bridge?.disconnectAll();
    _bridge = null;
    if (subscription != null) await subscription.cancel();
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {
        // Already closed.
      }
    }
    final firstReady = _firstReady;
    if (firstReady != null && !firstReady.isCompleted) {
      firstReady.completeError(
        const RelayException('Relay stopped before it connected.'),
      );
    }
    _firstReady = null;
    _messageQueue = Future<void>.value();
    if (closeRoom) {
      store?.clear();
      _session = null;
      _requestCache.clear();
    }
    _setState(RelayConnectionState.stopped);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (_ownsHttpClient) _httpClient.close(force: true);
    await _stateController.close();
  }

  Future<void> _connect(int run) async {
    if (!_enabled || run != _run) return;
    final selected = _session;
    if (selected == null) return;

    final serial = ++_socketSerial;
    _activeSocketSerial = serial;
    WebSocketChannel? candidate;
    try {
      candidate = _channelConnector(_hostWebSocketUri(selected.roomId));
      await candidate.ready.timeout(connectTimeout);
      if (!_enabled || run != _run || _activeSocketSerial != serial) {
        await candidate.sink.close();
        return;
      }

      _channel = candidate;
      _bridge = OnlineRelayBridge(
        controller: controller,
        send: (envelope) => _sendEnvelope(serial, envelope),
        requestCache: _requestCache,
      );
      _messageQueue = Future<void>.value();
      final handshake = Completer<void>();
      _handshake = handshake;
      _subscription = candidate.stream.listen(
        (data) => _receiveFrame(serial, data),
        onError: (Object error, StackTrace stackTrace) {
          _socketEnded(serial, error, stackTrace);
        },
        onDone: () {
          _socketEnded(
            serial,
            const RelayException('Relay connection closed.'),
            StackTrace.current,
          );
        },
        cancelOnError: true,
      );
      candidate.sink.add(
        jsonEncode({
          'type': 'host.auth',
          'secret': selected.hostSecret,
          'protocol': relayProtocolVersion,
        }),
      );
      await handshake.future.timeout(handshakeTimeout);
      if (!_enabled || run != _run || _activeSocketSerial != serial) return;
      _reconnectAttempt = 0;
      _lastError = null;
      _setState(RelayConnectionState.connected);
      final firstReady = _firstReady;
      if (firstReady != null && !firstReady.isCompleted) firstReady.complete();
    } catch (error, stackTrace) {
      if (_activeSocketSerial != serial) return;
      await _tearDownSocket(serial, closeChannel: true);
      _connectionFailed(run, error, stackTrace);
    }
  }

  void _receiveFrame(int serial, Object? data) {
    if (_activeSocketSerial != serial || data is! String) return;
    if (utf8.encode(data).length > _defaultMaxFrameBytes) {
      _socketEnded(
        serial,
        const RelayException('Relay frame was too large.'),
        StackTrace.current,
      );
      return;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final type = decoded['type'];
    if (type == 'host.ready') {
      final handshake = _handshake;
      if (handshake != null && !handshake.isCompleted) handshake.complete();
      return;
    }
    final handshake = _handshake;
    if (type == 'relay.error' ||
        (type == 'host.error' && handshake != null && !handshake.isCompleted)) {
      final rawMessage = decoded['message'];
      final error = RelayException(
        rawMessage is String && rawMessage.isNotEmpty
            ? rawMessage
            : 'Relay rejected the host connection.',
      );
      if (handshake != null && !handshake.isCompleted) {
        handshake.completeError(error);
      }
      _socketEnded(serial, error, StackTrace.current);
      return;
    }

    // A host.error after authentication normally concerns one player that
    // disconnected during a send. Keep all other clients and the host socket
    // alive, but expose the diagnostic to the organizer UI.
    if (type == 'host.error') {
      final rawMessage = decoded['message'];
      _lastError = RelayException(
        rawMessage is String && rawMessage.isNotEmpty
            ? rawMessage
            : 'The relay rejected a host message.',
      );
      return;
    }

    if (handshake == null || !handshake.isCompleted) return;
    final bridge = _bridge;
    if (bridge == null) return;
    _messageQueue = _messageQueue
        .then((_) => bridge.handle(decoded))
        .catchError((Object _) {
          // Bad player traffic is isolated from the organizer connection.
        });
  }

  void _sendEnvelope(int serial, Map<String, dynamic> envelope) {
    if (_activeSocketSerial != serial || !_enabled) return;
    final channel = _channel;
    if (channel == null) return;
    try {
      final encoded = jsonEncode(envelope);
      if (utf8.encode(encoded).length > _defaultMaxFrameBytes) return;
      channel.sink.add(encoded);
    } catch (error, stackTrace) {
      _socketEnded(serial, error, stackTrace);
    }
  }

  void _socketEnded(int serial, Object error, StackTrace stackTrace) {
    if (_activeSocketSerial != serial) return;
    final run = _run;
    unawaited(
      _tearDownSocket(serial, closeChannel: true).then((_) {
        _connectionFailed(run, error, stackTrace);
      }),
    );
  }

  Future<void> _tearDownSocket(int serial, {required bool closeChannel}) async {
    if (_activeSocketSerial != serial) return;
    _activeSocketSerial = null;
    final channel = _channel;
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    final handshake = _handshake;
    _handshake = null;
    _bridge?.disconnectAll();
    _bridge = null;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(
        const RelayException('Relay connection closed during setup.'),
      );
    }
    if (subscription != null) await subscription.cancel();
    if (closeChannel && channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {
        // Already closed.
      }
    }
  }

  void _connectionFailed(int run, Object error, StackTrace stackTrace) {
    if (!_enabled || run != _run) return;
    _lastError = error;
    final firstReady = _firstReady;
    if (firstReady != null && !firstReady.isCompleted) {
      firstReady.completeError(error, stackTrace);
    }
    _setState(RelayConnectionState.reconnecting);
    _scheduleReconnect(run);
  }

  void _scheduleReconnect(int run) {
    if (!_enabled || run != _run) return;
    _reconnectTimer?.cancel();
    final minMs = minReconnectDelay.inMilliseconds;
    final maxMs = maxReconnectDelay.inMilliseconds;
    final exponent = min(_reconnectAttempt, 10);
    final scaled = minMs * (1 << exponent);
    final bounded = min(scaled, maxMs);
    final jittered = bounded == 0
        ? 0
        : (bounded * (0.75 + (_random.nextDouble() * 0.5))).round();
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(milliseconds: jittered), () {
      if (!_enabled || run != _run) return;
      _setState(RelayConnectionState.reconnecting);
      unawaited(_connect(run));
    });
  }

  Uri _endpoint(String first, [String? second, String? third]) {
    final prefix = baseUrl.pathSegments.where((part) => part.isNotEmpty);
    return baseUrl.replace(
      pathSegments: [...prefix, first, ?second, ?third],
      query: null,
      fragment: null,
    );
  }

  Uri _hostWebSocketUri(String roomId) {
    final httpUri = _endpoint('v1', 'rooms', roomId).replace(
      pathSegments: [..._endpoint('v1', 'rooms', roomId).pathSegments, 'host'],
    );
    return httpUri.replace(scheme: httpUri.scheme == 'https' ? 'wss' : 'ws');
  }

  void _setState(RelayConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _checkUsable() {
    if (_disposed) throw StateError('OnlineRelayClient is disposed.');
  }
}

Future<Object?> _readResponse(Response response, int maxBytes) async {
  final bytes = <int>[];
  await for (final chunk in response.read()) {
    if (bytes.length + chunk.length > maxBytes) throw const _ResponseTooLarge();
    bytes.addAll(chunk);
  }
  if (bytes.isEmpty) return <String, dynamic>{};
  final text = utf8.decode(bytes, allowMalformed: false);
  try {
    return jsonDecode(text);
  } catch (_) {
    return text;
  }
}

Future<String> _readHttpResponse(
  HttpClientResponse response,
  int maxBytes,
) async {
  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const RelayException('The relay response was too large.');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes, allowMalformed: false);
}

bool _fitsJson(Object? value, int maxBytes) {
  try {
    return utf8.encode(jsonEncode(value)).length <= maxBytes;
  } catch (_) {
    return false;
  }
}

bool _validOpaqueId(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

bool _validRoomId(String value) =>
    value.length >= 20 &&
    value.length <= 64 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

bool _validRequestId(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value);

bool _validJoinUrl(String value, String roomId) {
  if (value.length > 2048) return false;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final segments = uri.pathSegments;
  final canonicalPath =
      segments.length == 2 || (segments.length == 3 && segments.last.isEmpty);
  return canonicalPath && segments[0] == 'r' && segments[1] == roomId;
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

String? _relayErrorMessage(Object? decoded) {
  if (decoded is! Map) return null;
  final error = decoded['error'];
  if (error is String && error.isNotEmpty) return error;
  if (error is Map) {
    final message = error['message'];
    if (message is String && message.isNotEmpty) return message;
  }
  final message = decoded['message'];
  return message is String && message.isNotEmpty ? message : null;
}

class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}
