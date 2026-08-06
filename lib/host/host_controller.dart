/// Flutter-side glue: owns the authoritative controller, starts/stops the
/// selected LAN or online transport and foreground service, persists state for
/// crash-resume, and exposes the host's own per-player snapshot to the UI.
///
/// The host is "just another client": its own player view goes through the
/// same ServerController commands a remote browser player uses.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf_static/shelf_static.dart';

import '../server/controller.dart';
import '../server/persistence.dart';
import '../server/server.dart';
import '../services/card_cache.dart';
import '../services/cloud_sync.dart';
import '../services/scryfall.dart';
import '../shared/cards.dart';
import '../shared/hosting.dart';
import '../shared/models.dart';
import 'foreground_task.dart';
import 'online_relay.dart';
import 'static_assets.dart';

const _configuredRelayUrl = String.fromEnvironment('MTG_RELAY_URL');

/// Provisioning key for a relay that restricts room creation. Public in the
/// APK, but revocable: see cloudflare/keys.mjs.
const _configuredRelayKey = String.fromEnvironment('MTG_RELAY_KEY');

/// The Stop button shown in the foreground-service notification (FR: organizer
/// can stop hosting from the notification shade without opening the app).
const List<NotificationButton> _notificationButtons = [
  NotificationButton(id: 'stop', text: 'Stop hosting'),
];

class HostController extends ChangeNotifier {
  final ServerController server = ServerController();
  final String relayBaseUrl;
  final String relayProvisionKey;

  // A key the organizer typed after the build's own key stopped being accepted
  // (revoked, rotated, or absent in a self-built APK). Kept in its own file,
  // never in the tournament JSON, so it cannot leak through a shared export.
  String? _relayKeyPath;
  String _storedRelayKey = '';

  /// The provisioning key to present to the relay: whatever the organizer
  /// entered most recently, otherwise the one compiled into this build.
  String get effectiveRelayProvisionKey =>
      _storedRelayKey.isNotEmpty ? _storedRelayKey : relayProvisionKey.trim();

  /// Remember a provisioning key the organizer entered. An empty [key] clears
  /// it and falls back to the build's own.
  Future<void> setRelayProvisionKey(String key) async {
    _storedRelayKey = key.trim();
    _relay?.provisionKey = effectiveRelayProvisionKey;
    final path = _relayKeyPath;
    if (path != null) {
      final file = File(path);
      try {
        if (_storedRelayKey.isEmpty) {
          if (file.existsSync()) await file.delete();
        } else {
          await file.writeAsString(_storedRelayKey, flush: true);
        }
      } catch (_) {
        // Storage is optional: the key still applies for this session.
      }
    }
    notifyListeners();
  }

  HttpServer? _http;
  OnlineRelayClient? _relay;
  OnlineRelaySessionStore? _relayStore;
  StreamSubscription<RelayConnectionState>? _relayStateSubscription;
  bool _hostingEnabled = false;
  int _transportGeneration = 0;
  bool _replacingExpiredRoom = false;
  String? _transportError;
  String? hostToken;
  String? hostPlayerId;
  String? lanIp;
  bool ready = false;
  bool _initialized = false;
  final int port = 8080;

  // Card images: Scryfall lookup (online, edit-time) + on-device cache (served
  // offline over the LAN). [cardSource] is overridable for tests.
  CardImageCache? imageCache;
  CardSource cardSource = ScryfallSource();
  String? _imageDirPath;

  bool get canEditCards => imageCache != null;

  // ---- Deck profile pictures --------------------------------------------
  // Plain files next to the card cache, keyed by deck id: a picture is a local
  // decoration, so it stays out of the persisted JSON (and the Drive backup).
  String? _avatarDirPath;

  /// The deck's profile picture, or null if it has none.
  File? deckAvatar(String deckId) {
    final dir = _avatarDirPath;
    if (dir == null) return null;
    final file = File('$dir/$deckId.img');
    return file.existsSync() ? file : null;
  }

  /// Replace (or, with a null [bytes], remove) a deck's profile picture.
  Future<void> setDeckAvatar(String deckId, List<int>? bytes) async {
    final dir = _avatarDirPath;
    if (dir == null) return;
    final file = File('$dir/$deckId.img');
    if (bytes == null) {
      if (file.existsSync()) await file.delete();
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
    notifyListeners();
  }

  // ---- Google account cloud backup (optional) ----
  final CloudSync cloud;
  // True once the user has picked "sign in" or "continue as guest" this launch —
  // dismisses the start-up account gate.
  bool _accountChosen = false;
  Timer? _cloudUploadTimer;

  /// Show the "Sign in with Google / continue as guest" gate only at the very
  /// start: no durable profile yet and no completed choice/sync this launch.
  /// A silent Google session alone must not bypass restore after a reinstall.
  bool get needsAccountGate => ready && server.owner == null && !_accountChosen;

  HostController({
    CloudSync? cloud,
    this.relayBaseUrl = _configuredRelayUrl,
    this.relayProvisionKey = _configuredRelayKey,
  }) : cloud = cloud ?? DriveCloudSync() {
    server.onChange = _onServerChanged;
    server.onDeckSaved = _onDeckSaved;
  }

  // Rebuild the UI on every server change, and proactively alert the organizer
  // (foreground notification) the instant a new match needs them — a result
  // mismatch or a reported infraction — since they may be on another screen or
  // have the phone locked.
  int _lastReviewCount = 0;
  void _onServerChanged() {
    notifyListeners();
    final n = server.pendingReviewCount;
    if (n > _lastReviewCount) _updateServiceNotification();
    _lastReviewCount = n;
    _scheduleCloudBackup();
  }

  /// Debounced best-effort push of the local save-blob to Drive after a change
  /// (only when signed in). Coalesces bursts of mutations into one upload.
  void _scheduleCloudBackup() {
    if (!cloud.isSignedIn) return;
    _cloudUploadTimer?.cancel();
    _cloudUploadTimer = Timer(
      const Duration(seconds: 4),
      () => unawaited(backupNow()),
    );
  }

  HostingMode get hostingMode => server.hostingMode ?? HostingMode.lan;
  bool get onlineHostingConfigured {
    final uri = Uri.tryParse(relayBaseUrl.trim());
    return uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' || (kDebugMode && uri.scheme == 'http'));
  }

  RelayConnectionState get relayState =>
      _relay?.state ?? RelayConnectionState.stopped;
  String? get transportError {
    final error = _transportError ?? _relay?.lastError;
    return error == null ? null : _friendlyTransportError(error);
  }

  bool get isServing => switch (hostingMode) {
    HostingMode.lan => _http != null && lanIp != null,
    HostingMode.online => relayState == RelayConnectionState.connected,
  };
  bool get hasActiveEvent => server.joinCode != null;

  /// True when an event is live but we are not currently serving it (the
  /// organizer pressed "Stop hosting" in the notification). The state is kept;
  /// hosting can be resumed.
  bool get hostingPaused => hasActiveEvent && !_hostingEnabled;

  String get hostingStatusLabel {
    if (hostingPaused) return 'Paused';
    if (hostingMode == HostingMode.lan) {
      if (_http == null) return 'Starting';
      return lanIp == null ? 'Needs network' : 'Live';
    }
    return switch (relayState) {
      RelayConnectionState.connected => 'Connected',
      RelayConnectionState.connecting => 'Connecting',
      RelayConnectionState.reconnecting => 'Reconnecting',
      RelayConnectionState.stopped =>
        transportError == null ? 'Starting' : 'Needs attention',
    };
  }

  Map<String, dynamic> get snapshot => server.snapshotFor(hostPlayerId);
  String? get joinUrl {
    final code = server.joinCode;
    if (code == null) return null;
    if (hostingMode == HostingMode.lan) {
      final ip = lanIp;
      return ip == null ? null : 'http://$ip:$port/?t=$code';
    }
    final raw = _relay?.joinUrl;
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return uri
        .replace(queryParameters: {...uri.queryParameters, 't': code})
        .toString();
  }

  /// Attach durable storage and resume an in-progress tournament if one was
  /// persisted (crash-recovery). Idempotent: safe to call from every screen
  /// that reads the shared controller; only the first call does the work.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // Receive the "Stop hosting" press from the service isolate.
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
    try {
      final dir = await getApplicationDocumentsDirectory();
      server.store = FilePersistence('${dir.path}/tournament.json');
      _relayStore = FileOnlineRelaySessionStore(
        '${dir.path}/online_relay_session.json',
      );
      _relayKeyPath = '${dir.path}/relay_provision_key.txt';
      final keyFile = File(_relayKeyPath!);
      if (keyFile.existsSync()) {
        _storedRelayKey = keyFile.readAsStringSync().trim();
      }
      final imgDir = Directory('${dir.path}/card_images');
      _imageDirPath = imgDir.path;
      imageCache = CardImageCache(imgDir);
      _avatarDirPath = (Directory(
        '${dir.path}/deck_avatars',
      )..createSync(recursive: true)).path;
      server.loadFromStore();
    } catch (_) {
      // storage unavailable (e.g. tests / desktop) — run without persistence,
      // but still give the editor a usable image cache (a temp dir) so card
      // editing never silently dead-ends with "Nothing to show".
      if (imageCache == null) {
        final tmp = Directory.systemTemp.createTempSync('mtg_card_images');
        _imageDirPath = tmp.path;
        imageCache = CardImageCache(tmp);
        _avatarDirPath = Directory.systemTemp
            .createTempSync('mtg_deck_avatars')
            .path;
      }
    }
    _relayStore ??= MemoryOnlineRelaySessionStore();
    if (server.joinCode != null) {
      hostPlayerId = server.hostPlayerId;
      hostToken = server.ownerToken;
      _hostingEnabled = true;
    }
    ready = true;
    notifyListeners();
    if (hasActiveEvent) unawaited(_resumeActiveHosting());
    // Resume a prior Google session in the BACKGROUND — never block app startup
    // on a network call (offline-first). When local durable state is empty (for
    // example after a reinstall), restore before dismissing the account gate.
    unawaited(_resumeCloudSession());
  }

  Future<void> _resumeCloudSession() async {
    try {
      if (await cloud.signInSilently()) {
        if (server.owner == null) {
          await _syncSignedInAccount();
          _accountChosen = true;
        }
        notifyListeners();
      }
    } catch (_) {
      // Do not let a half-restored account bypass the first-run gate. The user
      // can retry interactively or continue as a guest.
      if (server.owner == null) {
        try {
          await cloud.signOut();
        } catch (_) {
          // Best effort only; [_accountChosen] still keeps the gate visible.
        }
        notifyListeners();
      }
    }
  }

  // ========================================================================
  // Google account cloud backup
  // ========================================================================

  /// Interactive Google sign-in from the start gate / Profile. On success, fetch
  /// this account's cloud backup (the reinstall flow) and adopt it; if the
  /// account has no backup yet, seed it with the current local state. Returns
  /// false if the user cancelled or sign-in failed.
  Future<bool> signInToCloud() async {
    final ok = await cloud.signIn();
    if (!ok) return false;
    try {
      await _syncSignedInAccount();
    } catch (error, stackTrace) {
      // Authentication without a usable Drive backup is not a successful sync.
      // Return to a clean signed-out state so the gate/Profile can retry.
      try {
        await cloud.signOut();
      } catch (_) {
        // Preserve and report the original sync error.
      }
      notifyListeners();
      Error.throwWithStackTrace(error, stackTrace);
    }
    _accountChosen = true;
    notifyListeners();
    return true;
  }

  Future<void> _syncSignedInAccount() async {
    final remote = await cloud.download();
    final hadRemote = remote != null && remote.trim().isNotEmpty;
    if (hadRemote) {
      final previousEventId = server.engine?.id;
      final previousMode = server.hostingMode;
      if (!server.importJson(remote)) {
        throw const FormatException('Invalid Google Drive backup.');
      }
      hostPlayerId = server.hostPlayerId;
      hostToken = server.ownerToken;
      final transportChanged =
          previousEventId != server.engine?.id ||
          previousMode != server.hostingMode;
      if (transportChanged) {
        _transportGeneration++;
        await _relay?.stop();
        _relayStore?.clear();
        await _http?.close(force: true);
        _http = null;
        lanIp = null;
        await _stopForegroundService();
        _hostingEnabled = hasActiveEvent;
        if (hasActiveEvent) unawaited(_resumeActiveHosting());
      }
    }

    var createdGoogleOwner = false;
    if (server.owner == null) {
      final googleName = cloud.displayName?.trim() ?? '';
      if (googleName.isNotEmpty) {
        server.ensureOwner(googleName);
        server.persistAndNotify();
        createdGoogleOwner = true;
      }
    }

    // Seed a new backup, or repair an older ownerless backup with the Google
    // profile name. Existing cloud/custom nicknames are never overwritten.
    if (!hadRemote || createdGoogleOwner) {
      await cloud.upload(server.exportJson());
      if (createdGoogleOwner) {
        // [persistAndNotify] scheduled the same blob; the explicit upload above
        // has already completed it.
        _cloudUploadTimer?.cancel();
        _cloudUploadTimer = null;
      }
    }
  }

  /// Dismiss the start gate and use the app without cloud backup.
  void continueAsGuest() {
    _accountChosen = true;
    notifyListeners();
  }

  Future<void> signOutCloud() async {
    _cloudUploadTimer?.cancel();
    await cloud.signOut();
    notifyListeners();
  }

  /// Push the current local state to Drive now (explicit "Back up" action).
  Future<bool> backupNow() async {
    if (!cloud.isSignedIn) return false;
    try {
      await cloud.upload(server.exportJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Handles messages pushed from the foreground-service isolate. The only one
  /// today is the notification "Stop hosting" button.
  void _onServiceData(Object data) {
    if (data == 'stopHosting') pauseHosting();
  }

  OnlineRelayClient _onlineRelay() {
    final existing = _relay;
    if (existing != null) {
      // A key entered after the built-in one was revoked applies immediately.
      existing.provisionKey = effectiveRelayProvisionKey;
      return existing;
    }
    if (!onlineHostingConfigured) {
      throw StateError(
        'Online hosting is not configured in this build. Set MTG_RELAY_URL '
        'to the deployed Cloudflare Worker URL.',
      );
    }
    final relay = OnlineRelayClient(
      controller: server,
      baseUrl: Uri.parse(relayBaseUrl.trim()),
      provisionKey: effectiveRelayProvisionKey,
      store: _relayStore ??= MemoryOnlineRelaySessionStore(),
    );
    _relayStateSubscription = relay.stateChanges.listen((state) {
      final error = relay.lastError;
      _transportError = error == null ? null : _friendlyTransportError(error);
      notifyListeners();
      unawaited(_updateServiceNotification());
      if (state == RelayConnectionState.reconnecting &&
          _hostingEnabled &&
          hasActiveEvent &&
          hostingMode == HostingMode.online &&
          _relayNeedsReplacement(error)) {
        unawaited(_replaceExpiredOnlineRoom());
      }
    });
    return _relay = relay;
  }

  Future<void> _resumeActiveHosting() async {
    if (!hasActiveEvent || !_hostingEnabled) return;
    final generation = ++_transportGeneration;
    final eventId = server.engine!.id;
    final mode = hostingMode;
    _transportError = null;
    notifyListeners();
    try {
      if (mode == HostingMode.online) {
        final relay = _onlineRelay();
        var session = _relayStore?.load();
        final relayUri = Uri.parse(relayBaseUrl.trim());
        if (session?.eventId != server.engine?.id ||
            (session != null &&
                (session.isExpired() || !session.belongsTo(relayUri)))) {
          _relayStore?.clear();
          session = null;
        }
        session ??= await relay.provision();
        if (!_transportIsCurrent(generation, eventId, mode)) {
          await _cleanupCancelledTransport(mode);
          return;
        }
        session = session.copyWith(eventId: eventId);
        await relay.start(session);
      } else {
        await _ensureServer();
      }
    } catch (error) {
      if (!_transportIsCurrent(generation, eventId, mode)) {
        await _cleanupCancelledTransport(mode);
        return;
      }
      _transportError = _friendlyTransportError(error);
      notifyListeners();
    }
    if (!_transportIsCurrent(generation, eventId, mode)) {
      await _cleanupCancelledTransport(mode);
      return;
    }
    try {
      await _startForegroundService();
    } catch (error) {
      if (!_transportIsCurrent(generation, eventId, mode)) {
        await _cleanupCancelledTransport(mode);
        return;
      }
      _transportError ??= _friendlyTransportError(error);
      notifyListeners();
    }
    if (!_transportIsCurrent(generation, eventId, mode)) {
      await _cleanupCancelledTransport(mode);
    }
  }

  bool _transportIsCurrent(int generation, String eventId, HostingMode mode) =>
      generation == _transportGeneration &&
      _hostingEnabled &&
      server.engine?.id == eventId &&
      hostingMode == mode;

  Future<void> _cleanupCancelledTransport(HostingMode attemptedMode) async {
    // A newer generation may intentionally own the same transport. Only tear
    // it down when hosting was cancelled or the event/mode actually changed.
    if (_hostingEnabled && hasActiveEvent && hostingMode == attemptedMode) {
      return;
    }
    if (attemptedMode == HostingMode.online) {
      await _relay?.stop();
    } else {
      await _http?.close(force: true);
      _http = null;
      lanIp = null;
    }
    if (!_hostingEnabled || !hasActiveEvent) {
      await _stopForegroundService();
    }
  }

  bool _relayNeedsReplacement(Object? error) {
    final session = _relayStore?.load();
    if (session?.isExpired() ?? false) return true;
    final text = error?.toString().toLowerCase() ?? '';
    return text.contains('room expired') || text.contains('room_expired');
  }

  Future<void> _replaceExpiredOnlineRoom() async {
    if (_replacingExpiredRoom) return;
    _replacingExpiredRoom = true;
    try {
      await retryHosting(replaceOnlineRoom: true);
    } finally {
      _replacingExpiredRoom = false;
    }
  }

  String _friendlyTransportError(Object error) {
    if (relayNeedsProvisionKey(error)) {
      return 'This relay needs a current provisioning key. Start the event '
          'again to enter one.';
    }
    final text = error.toString();
    return text.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
  }

  /// Retry a transport without turning a temporary online outage into a manual
  /// pause. The relay itself also reconnects automatically with backoff.
  Future<void> retryHosting({bool replaceOnlineRoom = false}) async {
    if (!hasActiveEvent) return;
    if (!_hostingEnabled) return resumeHosting();
    _transportGeneration++;
    if (hostingMode == HostingMode.online) {
      final saved = _relayStore?.load();
      final relayUri = Uri.parse(relayBaseUrl.trim());
      final needsReplacement =
          replaceOnlineRoom ||
          saved == null ||
          saved.isExpired() ||
          !saved.belongsTo(relayUri) ||
          _relayNeedsReplacement(_relay?.lastError);
      await _relay?.stop();
      if (needsReplacement) _relayStore?.clear();
    } else {
      await _http?.close(force: true);
      _http = null;
      lanIp = null;
    }
    await _resumeActiveHosting();
  }

  // Serialises startup: concurrent callers (e.g. a rapid double-tap on "Resume
  // hosting") share one in-flight future instead of both racing to bind :8080
  // and the loser throwing "address already in use".
  Future<void>? _starting;
  Future<void> _ensureServer() {
    if (_http != null) return Future.value();
    return _starting ??= _doEnsureServer();
  }

  Future<void> _doEnsureServer() async {
    try {
      final webDir = await extractWebAssets();
      final staticHandler = createStaticHandler(
        webDir,
        defaultDocument: 'index.html',
      );
      _http = await serveController(
        server,
        port: port,
        staticHandler: staticHandler,
        imageDirPath: _imageDirPath,
      );
      lanIp = await lanIpv4();
      if (lanIp == null) {
        _transportError =
            'No LAN address is available. Connect to Wi-Fi and retry.';
      }
    } finally {
      _starting = null;
    }
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mtg_hosting',
        channelName: 'Tournament hosting',
        channelDescription:
            'Keeps LAN and online tournaments reachable during an event.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      // Battery-tuned: NO periodic events and NO CPU wake lock — the CPU is
      // free to idle between requests and inbound network packets wake it. We
      // only hold a Wi-Fi lock so the radio doesn't deep-sleep and drop clients.
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: false,
        allowWifiLock: hostingMode == HostingMode.lan,
      ),
    );
    await FlutterForegroundTask.requestNotificationPermission();
    // Start the service first so hosting is live immediately, then ask for the
    // Doze exemption — the dialog must never gate the server coming up.
    await FlutterForegroundTask.startService(
      serviceId: 4242,
      notificationTitle: 'Hosting "${server.engine?.name ?? 'tournament'}"',
      notificationText:
          '${hostingMode.label} · players join with code ${server.joinCode}',
      notificationButtons: _notificationButtons,
      callback: hostingTaskCallback,
    );
    await _ensureBatteryExemption();
  }

  Future<void> _stopForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // The service may already have stopped from its notification action or
      // because the platform reclaimed the process.
    }
  }

  /// Ask the OS to exempt the app from battery optimization / Doze so the LAN
  /// server stays reachable with the screen off. Shown once; safe if declined.
  Future<void> _ensureBatteryExemption() async {
    try {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (_) {
      // user may decline — hosting still works, just keep the screen on
    }
  }

  Future<void> _updateServiceNotification() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    final reviews = server.pendingReviewCount;
    await FlutterForegroundTask.updateService(
      notificationTitle: reviews > 0
          ? '⚠ Tournament needs you'
          : 'Hosting "${server.engine?.name ?? 'tournament'}"',
      notificationText: reviews > 0
          ? '$reviews match${reviews == 1 ? '' : 'es'} to resolve — result or infraction'
          : server.engine == null
          ? 'Lobby open · code ${server.joinCode}'
          : '${hostingMode.label} · Round ${server.engine!.rounds.length} · ${server.engine!.entries.length} players',
      // Re-pass the buttons so the Stop action survives notification rebuilds.
      notificationButtons: _notificationButtons,
    );
  }

  /// Stop serving and tear down the foreground service WITHOUT discarding the
  /// event — invoked by the notification "Stop hosting" button. The tournament
  /// stays persisted and can be resumed with [resumeHosting].
  Future<void> pauseHosting() async {
    _hostingEnabled = false;
    _transportGeneration++;
    if (hostingMode == HostingMode.online) {
      await _relay?.stop();
    } else {
      await _http?.close(force: true);
      _http = null;
      lanIp = null;
    }
    await _stopForegroundService();
    notifyListeners();
  }

  /// Bring a paused event back online using its original LAN/online mode.
  Future<void> resumeHosting() async {
    if (!hasActiveEvent) return;
    _hostingEnabled = true;
    await _resumeActiveHosting();
  }

  Future<String> createEvent({
    required String name,
    required String nickname,
    required HostingMode mode,
    TournamentKind kind = TournamentKind.swiss,
    String format = '',
    String series = '',
    int rounds = 0,
    int roundMinutes = 0,
  }) async {
    if (hasActiveEvent) throw StateError('A tournament is already active.');
    final generation = ++_transportGeneration;
    OnlineRelaySession? onlineSession;
    if (mode == HostingMode.online) {
      final relay = _onlineRelay();
      // Never reuse credentials left by an event that was already ended.
      _relayStore?.clear();
      onlineSession = await relay.provision();
    } else {
      await _ensureServer();
    }
    if (generation != _transportGeneration || hasActiveEvent) {
      if (onlineSession != null) await _relay?.stop(closeRoom: true);
      throw StateError('Tournament creation was cancelled.');
    }
    // The host plays as this device's durable owner identity.
    final s = server.ensureOwner(nickname);
    hostToken = s.token;
    hostPlayerId = s.playerId;
    final code = server.createTournament(
      name: name,
      hostPlayerId: s.playerId,
      mode: mode,
      kind: kind,
      format: format,
      series: series,
      rounds: rounds,
      roundMinutes: roundMinutes,
    );
    final eventId = server.engine!.id;
    _hostingEnabled = true;
    _transportError = null;
    if (onlineSession != null) {
      try {
        await _relay!.start(onlineSession.copyWith(eventId: eventId));
      } catch (error) {
        // The room is provisioned and reconnect remains enabled; keep the
        // tournament so the organizer can see its status and retry.
        _transportError = _friendlyTransportError(error);
      }
    }
    if (!_transportIsCurrent(generation, eventId, mode)) {
      await _cleanupCancelledTransport(mode);
      throw StateError('Tournament creation was cancelled.');
    }
    try {
      await _startForegroundService();
    } catch (error) {
      // Hosting is already live (and the event is durably created). A service
      // notification failure must not prevent the host deck from being seated.
      _transportError ??= _friendlyTransportError(error);
    }
    if (!_transportIsCurrent(generation, eventId, mode)) {
      await _cleanupCancelledTransport(mode);
      throw StateError('Tournament creation was cancelled.');
    }
    notifyListeners();
    return code;
  }

  void registerHostDeck({
    required String name,
    required String main,
    required String side,
  }) {
    final d = server.saveDeck(
      ownerId: hostPlayerId!,
      name: name,
      mainboard: main,
      sideboard: side,
    );
    server.joinTournament(playerId: hostPlayerId!, deckId: d.id);
  }

  /// Seat the host into the active event using one of their EXISTING saved decks
  /// (vs. [registerHostDeck], which always creates a new one).
  void joinWithDeck(String deckId) =>
      server.joinTournament(playerId: hostPlayerId!, deckId: deckId);

  /// Register a deck for the device owner outside an event (Decks tab). Creates
  /// the durable owner identity on first use if needed.
  void registerDeck({
    required String nickname,
    required String name,
    required String main,
    required String side,
    String archetype = '',
  }) {
    final s = server.ensureOwner(nickname);
    // saveDeck already persists + broadcasts (and triggers background image
    // resolution), so no explicit persistAndNotify is needed here.
    server.saveDeck(
      ownerId: s.playerId,
      name: name,
      mainboard: main,
      sideboard: side,
      archetype: archetype,
    );
  }

  /// Label a deck with an archetype so it groups with other players' versions
  /// of the same deck in matchup statistics. Purely a statistics label — it
  /// changes nothing about the list or any past result.
  void setDeckArchetype(String deckId, String archetype) {
    final d = server.decks[deckId];
    if (d == null) return;
    server.decks[deckId] = d.copyWith(archetype: archetype.trim());
    server.persistAndNotify();
  }

  /// Set or update the device owner's nickname (Profile tab).
  void setNickname(String nickname) {
    server.ensureOwner(nickname);
    server.persistAndNotify();
  }

  /// Permanently delete an archived tournament from history (Events tab).
  void deleteArchived(String tournamentId) =>
      server.deleteArchived(tournamentId);

  // ========================================================================
  // Card images (Scryfall resolve + cache) — deck editor support
  // ========================================================================

  /// Name suggestions for the editor's "add card" search.
  Future<List<String>> autocompleteCards(String query) =>
      cardSource.autocomplete(query);

  /// Fired by [ServerController.onDeckSaved] whenever ANY deck is saved — the
  /// organizer's own deck or a participant's via POST /api/deck. Kicks off image
  /// resolution off the request/UI thread so the deck shows in card format
  /// automatically, no manual "fetch" tap. Best-effort: offline failures are
  /// swallowed (the typed list is preserved) and a later retry fills them in.
  void _onDeckSaved(String deckId) =>
      unawaited(_resolveDeckInBackground(deckId));

  Future<void> _resolveDeckInBackground(String deckId) async {
    if (!canEditCards) return; // no image cache (headless / no storage)
    final d = server.decks[deckId];
    if (d == null) return;
    // Already-structured deck with no pending text → nothing to fetch.
    if (d.hasCards &&
        d.mainboardText.trim().isEmpty &&
        d.sideboardText.trim().isEmpty) {
      return;
    }
    try {
      await resolveDeckFromText(deckId);
    } catch (_) {
      // offline / DNS failure — resolveDeckFromText keeps the text; ignore.
    }
  }

  /// Resolve a (possibly imperfect) card name via Scryfall, register its
  /// metadata in the catalog, and cache its image. Reuses an already-cached
  /// catalog entry of the same name to avoid a network round-trip. Returns the
  /// resolved card, or null if not found / offline.
  Future<CardInfo?> resolveAndCacheCard(String name) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    CardInfo? existing;
    for (final ci in server.cardCatalog.values) {
      if (ci.name.toLowerCase() == n.toLowerCase()) {
        existing = ci;
        break;
      }
    }
    if (existing != null && (imageCache?.isCached(existing.id) ?? false)) {
      return existing;
    }
    final info = existing ?? await cardSource.resolve(n);
    if (info == null) return null;
    server.registerCards([info]);
    await _cacheImage(info);
    return info;
  }

  /// Cache [info]'s image if not already present. Returns true when the image
  /// is on disk afterwards (already cached, or downloaded now); false when there
  /// is nothing to download (empty url / no cache) or the download failed.
  Future<bool> _cacheImage(CardInfo info) async {
    final cache = imageCache;
    if (cache == null) return false;
    if (cache.isCached(info.id)) return true;
    if (info.imageUrl.isEmpty) return false;
    try {
      final bytes = await cardSource.fetchImage(info.imageUrl);
      await cache.store(info.id, bytes);
      return true;
    } catch (_) {
      // image fetch failed (offline / 404) — keep metadata, the card just shows
      // as a text placeholder until a later download succeeds.
      return false;
    }
  }

  /// Parse a deck's free-text lists, resolve every line via Scryfall, cache the
  /// images, and store the structured result. Reports (done, total) progress so
  /// the editor can show a progress bar.
  ///
  /// Returns a summary of how many lines resolved vs. failed (offline / unknown
  /// name) so the caller can tell the user to retry. Crucially, the user's
  /// original typed decklist text is NEVER overwritten unless every line
  /// resolved — a failed/partial fetch (e.g. offline) leaves the text intact so
  /// nothing is lost and a later retry re-reads the full list.
  Future<({int resolved, int failed, List<String> failedNames})>
  resolveDeckFromText(
    String deckId, {
    void Function(int done, int total)? onProgress,
  }) async {
    final d = server.decks[deckId];
    if (d == null) {
      return (resolved: 0, failed: 0, failedNames: const <String>[]);
    }
    final mainLines = parseDecklist(d.mainboardText);
    final sideLines = parseDecklist(d.sideboardText);
    final total = mainLines.length + sideLines.length;
    var done = 0;
    final failedNames = <String>[];
    onProgress?.call(0, total);

    // Resolve names to metadata first (serial, rate-limited API), deduped by
    // name so a 4-of only hits Scryfall once. Images are downloaded afterwards
    // in parallel — that split is what makes a full deck fetch fast.
    final byName = <String, CardInfo?>{};
    Future<CardInfo?> resolveMeta(String name) async {
      final key = name.trim().toLowerCase();
      if (byName.containsKey(key)) return byName[key];
      CardInfo? info;
      for (final ci in server.cardCatalog.values) {
        if (ci.name.toLowerCase() == key) {
          info = ci;
          break;
        }
      }
      if (info == null) {
        try {
          info = await cardSource.resolve(name);
        } catch (_) {
          info = null; // network exception — count as failed, keep going
        }
        if (info != null) server.registerCards([info]);
      }
      byName[key] = info;
      return info;
    }

    // Ask for every unknown name in one batched request before walking the
    // lines. Without this each distinct card costs its own rate-limited round
    // trip, which is what made importing a deck take seconds per card.
    final known = <String>{
      for (final ci in server.cardCatalog.values) ci.name.toLowerCase(),
    };
    final unknown = <String, String>{};
    for (final line in [...mainLines, ...sideLines]) {
      final key = line.name.trim().toLowerCase();
      if (!known.contains(key)) {
        unknown.putIfAbsent(key, () => line.name.trim());
      }
    }
    if (unknown.isNotEmpty) {
      try {
        final batch = await cardSource.resolveAll(unknown.values.toList());
        byName.addAll(batch);
        server.registerCards(batch.values.toSet().toList());
      } catch (_) {
        // Offline or a failed batch: every line still falls back to the
        // single-card path below, which records the failures individually.
      }
    }

    Future<List<DeckCardEntry>> run(List<ParsedLine> lines) async {
      final out = <DeckCardEntry>[];
      for (final l in lines) {
        final info = await resolveMeta(l.name);
        done++;
        onProgress?.call(done, total);
        if (info != null) {
          _merge(out, info.id, l.qty);
        } else {
          failedNames.add(l.name);
        }
      }
      return out;
    }

    final main = await run(mainLines);
    final side = await run(sideLines);
    // Download every resolved card's image in parallel (CDN, not rate-limited).
    await Future.wait(byName.values.whereType<CardInfo>().map(_cacheImage));
    // Only persist if something resolved; preserve the original text whenever
    // any line failed so a partial result never shrinks the user's decklist.
    if (main.isNotEmpty || side.isNotEmpty) {
      server.setDeckCards(
        deckId: deckId,
        main: main,
        side: side,
        keepText: failedNames.isNotEmpty,
      );
    }
    return (
      resolved: total - failedNames.length,
      failed: failedNames.length,
      failedNames: failedNames,
    );
  }

  static void _merge(List<DeckCardEntry> out, String id, int qty) {
    final i = out.indexWhere((e) => e.cardId == id);
    if (i >= 0) {
      out[i] = out[i].copyWith(qty: out[i].qty + qty);
    } else {
      out.add(DeckCardEntry(id, qty));
    }
  }

  /// Prep step before going offline: ensure every card image referenced by any
  /// registered deck is cached (resolving text-only decks into structured cards
  /// first). Reports (done, total) continuously across BOTH the resolve and the
  /// download phases so the progress bar never sits frozen.
  ///
  /// Returns honest counts so the UI can warn instead of falsely claiming
  /// success: [imagesCached]/[imagesFailed] for image downloads and
  /// [linesFailed] for deck lines that couldn't be resolved at all.
  Future<({int requested, int imagesCached, int imagesFailed, int linesFailed})>
  downloadAllDeckImages({
    void Function(int done, int total)? onProgress,
  }) async {
    // Phase 1 — resolve text-only decks. Estimate work as the parsed line count.
    final textDecks = server.decks.values
        .where(
          (d) =>
              !d.hasCards &&
              (d.mainboardText.trim().isNotEmpty ||
                  d.sideboardText.trim().isNotEmpty),
        )
        .toList();
    var grand = 0;
    for (final d in textDecks) {
      grand +=
          parseDecklist(d.mainboardText).length +
          parseDecklist(d.sideboardText).length;
    }
    var done = 0;
    var base = 0;
    var linesFailed = 0;
    onProgress?.call(done, grand);
    for (final d in textDecks) {
      final myBase = base;
      final lines =
          parseDecklist(d.mainboardText).length +
          parseDecklist(d.sideboardText).length;
      final summary = await resolveDeckFromText(
        d.id,
        onProgress: (dn, _) {
          done = myBase + dn;
          onProgress?.call(done, grand);
        },
      );
      linesFailed += summary.failed;
      base += lines;
    }
    done = base;

    // Phase 2 — download images still missing for already-structured cards
    // (skip image-less cards, which have nothing to download).
    final ids = <String>{};
    for (final d in server.decks.values) {
      for (final e in [...d.mainCards, ...d.sideCards]) {
        ids.add(e.cardId);
      }
    }
    final missing = ids.where((id) {
      final info = server.cardCatalog[id];
      return info != null &&
          info.imageUrl.isNotEmpty &&
          !(imageCache?.isCached(id) ?? true);
    }).toList();
    grand = base + missing.length;
    onProgress?.call(done, grand);
    var imagesCached = 0, imagesFailed = 0;
    // Parallel downloads (HttpClient bounds real concurrency per host). The
    // counters are safe to ++ across these futures — Dart async is single-thread.
    await Future.wait(
      missing.map((id) async {
        final ok = await _cacheImage(server.cardCatalog[id]!);
        ok ? imagesCached++ : imagesFailed++;
        done++;
        onProgress?.call(done, grand);
      }),
    );
    return (
      requested: missing.length,
      imagesCached: imagesCached,
      imagesFailed: imagesFailed,
      linesFailed: linesFailed,
    );
  }

  // host authority
  void start() {
    server.startTournament();
    _updateServiceNotification();
  }

  void advance() {
    server.advanceRound();
    _updateServiceNotification();
  }

  void resolve(String matchId, int p1Wins, int p2Wins) =>
      server.hostResolve(matchId, p1Wins, p2Wins);
  void drop(String playerId) => server.dropPlayer(playerId);

  void setRounds(int rounds) => server.setPlannedRounds(rounds);
  void setRoundMinutes(int minutes) => server.setRoundMinutes(minutes);
  void startRoundTimer() => server.startRoundTimer();
  void stopRoundTimer() => server.stopRoundTimer();
  void swapPairing(String playerA, String playerB) =>
      server.swapPairing(playerA, playerB);

  /// End the event, stop the service, and clear the durable tournament (keeps
  /// players/decks for the next event).
  Future<void> endEvent() async {
    _hostingEnabled = false;
    _transportGeneration++;
    if (hostingMode == HostingMode.online) {
      try {
        await _relay?.stop(closeRoom: true);
      } catch (_) {
        // The relay also expires abandoned rooms server-side.
      }
      _relayStore?.clear();
    } else {
      await _http?.close(force: true);
    }
    server.clearTournament();
    hostPlayerId = null;
    hostToken = null;
    _http = null;
    lanIp = null;
    _transportError = null;
    await _stopForegroundService();
    notifyListeners();
  }

  // host-as-player (canonical orientation handled server-side)
  void submit(String matchId, int mineWon, int oppWon, [int draws = 0]) =>
      server.submitResult(
        playerId: hostPlayerId!,
        matchId: matchId,
        mineWon: mineWon,
        oppWon: oppWon,
        draws: draws,
      );
  void infraction(String matchId, bool ok) => server.confirmInfraction(
    playerId: hostPlayerId!,
    matchId: matchId,
    ok: ok,
  );

  @override
  void dispose() {
    // The server is intentionally NOT stopped here: this controller is shared
    // app-wide, and leaving a screen should not kill an in-progress event. Use
    // endEvent() to tear down.
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    _hostingEnabled = false;
    _transportGeneration++;
    _cloudUploadTimer?.cancel();
    unawaited(_relayStateSubscription?.cancel());
    final relay = _relay;
    if (relay != null) unawaited(relay.dispose());
    if (cardSource case final ScryfallSource source) source.close();
    super.dispose();
  }
}
