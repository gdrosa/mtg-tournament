/// Flutter-side glue: owns the embedded server + controller, starts/stops the
/// LAN listener and the keep-alive foreground service, persists state for
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
import 'foreground_task.dart';
import 'static_assets.dart';

/// The Stop button shown in the foreground-service notification (FR: organizer
/// can stop hosting from the notification shade without opening the app).
const List<NotificationButton> _notificationButtons = [
  NotificationButton(id: 'stop', text: 'Stop hosting'),
];

class HostController extends ChangeNotifier {
  final ServerController server = ServerController();
  HttpServer? _http;
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

  // ---- Google account cloud backup (optional) ----
  final DriveCloudSync cloud = DriveCloudSync();
  // True once the user has picked "sign in" or "continue as guest" this launch —
  // dismisses the start-up account gate.
  bool _accountChosen = false;
  Timer? _cloudUploadTimer;

  /// Show the "Sign in with Google / continue as guest" gate only at the very
  /// start: no durable profile yet and no completed choice/sync this launch.
  /// A silent Google session alone must not bypass restore after a reinstall.
  bool get needsAccountGate => ready && server.owner == null && !_accountChosen;

  HostController() {
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

  bool get isServing => _http != null;
  bool get hasActiveEvent => server.joinCode != null;

  /// True when an event is live but we are not currently serving it (the
  /// organizer pressed "Stop hosting" in the notification). The state is kept;
  /// hosting can be resumed.
  bool get hostingPaused => hasActiveEvent && !isServing;

  Map<String, dynamic> get snapshot => server.snapshotFor(hostPlayerId);
  String get joinUrl =>
      'http://${lanIp ?? 'localhost'}:$port/?t=${server.joinCode}';

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
      final imgDir = Directory('${dir.path}/card_images');
      _imageDirPath = imgDir.path;
      imageCache = CardImageCache(imgDir);
      server.loadFromStore();
      if (server.joinCode != null) {
        hostPlayerId = server.hostPlayerId;
        hostToken = server.ownerToken;
        await _ensureServer();
        await _startForegroundService();
      }
    } catch (_) {
      // storage unavailable (e.g. tests / desktop) — run without persistence,
      // but still give the editor a usable image cache (a temp dir) so card
      // editing never silently dead-ends with "Nothing to show".
      if (imageCache == null) {
        final tmp = Directory.systemTemp.createTempSync('mtg_card_images');
        _imageDirPath = tmp.path;
        imageCache = CardImageCache(tmp);
      }
    }
    ready = true;
    notifyListeners();
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
    if (remote != null && remote.trim().isNotEmpty) {
      if (!server.importJson(remote)) {
        throw const FormatException('Invalid Google Drive backup.');
      }
      hostPlayerId = server.hostPlayerId;
      hostToken = server.ownerToken;
    } else {
      await cloud.upload(server.exportJson());
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
        channelDescription: 'Keeps the LAN server reachable during an event.',
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
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.requestNotificationPermission();
    // Start the service first so hosting is live immediately, then ask for the
    // Doze exemption — the dialog must never gate the server coming up.
    await FlutterForegroundTask.startService(
      serviceId: 4242,
      notificationTitle: 'Hosting "${server.engine?.name ?? 'tournament'}"',
      notificationText: 'Players join with code ${server.joinCode}',
      notificationButtons: _notificationButtons,
      callback: hostingTaskCallback,
    );
    await _ensureBatteryExemption();
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
          : 'Round ${server.engine!.rounds.length} · ${server.engine!.entries.length} players',
      // Re-pass the buttons so the Stop action survives notification rebuilds.
      notificationButtons: _notificationButtons,
    );
  }

  /// Stop serving and tear down the foreground service WITHOUT discarding the
  /// event — invoked by the notification "Stop hosting" button. The tournament
  /// stays persisted and can be resumed with [resumeHosting].
  Future<void> pauseHosting() async {
    await _http?.close(force: true);
    _http = null;
    lanIp = null;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // service already stopped (e.g. the button handler stopped it first)
    }
    notifyListeners();
  }

  /// Bring a paused event back online: restart the LAN server + service.
  Future<void> resumeHosting() async {
    if (!hasActiveEvent) return;
    await _ensureServer();
    await _startForegroundService();
    notifyListeners();
  }

  Future<String> createEvent({
    required String name,
    required String nickname,
  }) async {
    await _ensureServer();
    // The host plays as this device's durable owner identity.
    final s = server.ensureOwner(nickname);
    hostToken = s.token;
    hostPlayerId = s.playerId;
    final code = server.createTournament(name: name, hostPlayerId: s.playerId);
    await _startForegroundService();
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
  }) {
    final s = server.ensureOwner(nickname);
    // saveDeck already persists + broadcasts (and triggers background image
    // resolution), so no explicit persistAndNotify is needed here.
    server.saveDeck(
      ownerId: s.playerId,
      name: name,
      mainboard: main,
      sideboard: side,
    );
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

  /// End the event, stop the service, and clear the durable tournament (keeps
  /// players/decks for the next event).
  Future<void> endEvent() async {
    server.clearTournament();
    hostPlayerId = null;
    hostToken = null;
    await _http?.close(force: true);
    _http = null;
    lanIp = null;
    await FlutterForegroundTask.stopService();
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
    _cloudUploadTimer?.cancel();
    if (cardSource case final ScryfallSource source) source.close();
    super.dispose();
  }
}
