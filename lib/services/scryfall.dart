/// Scryfall card lookup + image fetch (the ONLY runtime-internet code path).
///
/// Used at deck-edit / prep time while the host has internet; the results are
/// cached locally ([CardImageCache]) and served from cache during the offline
/// LAN tournament, satisfying NFR-13/14 (no internet on any in-tournament path).
///
/// [CardSource] is an interface so the orchestration is unit-testable with a
/// fake (no network); [ScryfallSource] is the real `dart:io` implementation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../shared/cards.dart';

/// Resolves card names to [CardInfo] and downloads card images.
abstract class CardSource {
  /// Best-effort resolve a (possibly imperfect) card name to one printing.
  Future<CardInfo?> resolve(String name);

  /// Name suggestions for the editor's "add card" search box.
  Future<List<String>> autocomplete(String query);

  /// Resolve many exact card names at once, keyed by lower-cased name. Names
  /// that do not resolve are simply absent; the caller can retry those one by
  /// one through the fuzzy [resolve].
  ///
  /// The default implementation is one [resolve] per name, which keeps test
  /// fakes working; [ScryfallSource] overrides it with a batched request.
  Future<Map<String, CardInfo>> resolveAll(List<String> names) async {
    final out = <String, CardInfo>{};
    for (final name in names) {
      final info = await resolve(name);
      if (info != null) out[name.trim().toLowerCase()] = info;
    }
    return out;
  }

  /// Download the image bytes at [url].
  Future<List<int>> fetchImage(String url);
}

/// Live Scryfall implementation. Polite by default: a short delay between
/// requests and an identifying User-Agent, per Scryfall's API guidelines.
class ScryfallSource implements CardSource {
  static const _api = 'https://api.scryfall.com';
  // Cap concurrent connections per host: image downloads (cards.scryfall.io) run
  // in parallel up to this many at once; HttpClient queues the rest. API calls
  // (api.scryfall.com) stay serial via [_throttled] regardless.
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..maxConnectionsPerHost = 8;
  final Duration minGap;

  /// Automatic retries for transient failures (HTTP 429 / 5xx). Genuine misses
  /// (404) are not retried.
  final int maxRetries;
  Future<void> _chain = Future.value();

  ScryfallSource({
    this.minGap = const Duration(milliseconds: 90),
    this.maxRetries = 2,
  });

  /// Serialise + space out requests so we never hammer Scryfall.
  Future<T> _throttled<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
      await Future<void>.delayed(minGap);
    });
    return completer.future;
  }

  Future<Map<String, dynamic>?> _getJson(String url) =>
      _throttled(() => _getJsonOnce(url, attempt: 0));

  Future<Map<String, dynamic>?> _getJsonOnce(
    String url, {
    required int attempt,
  }) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'mtg-tourney/1.0');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close();
    if (resp.statusCode == 200) {
      final body = await resp.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    }
    final retryAfter = _retryAfter(resp);
    await resp.drain<void>();
    // 429 / 5xx are transient — back off and retry so a momentary rate-limit
    // doesn't silently drop cards from a bulk deck resolve. 404 etc. are real
    // misses and return null immediately.
    if (_isTransient(resp.statusCode) && attempt < maxRetries) {
      await Future<void>.delayed(retryAfter ?? _backoff(attempt));
      return _getJsonOnce(url, attempt: attempt + 1);
    }
    return null;
  }

  @override
  Future<CardInfo?> resolve(String name) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final j = await _getJson(
      '$_api/cards/named?fuzzy=${Uri.encodeQueryComponent(n)}',
    );
    if (j == null) return null;
    // Keep the card even if no image could be selected (it renders as a text
    // placeholder) — don't drop a valid card just because of its layout.
    return cardInfoFromScryfall(j);
  }

  /// Scryfall accepts at most 75 identifiers per `/cards/collection` request.
  static const _collectionBatch = 75;

  @override
  Future<Map<String, CardInfo>> resolveAll(List<String> names) async {
    // One request per 75 cards instead of one per card: a 75-card decklist of
    // ~25 distinct names resolves in a single round trip rather than 25.
    final unique = <String, String>{}; // lower-cased key -> name as typed
    for (final raw in names) {
      final name = raw.trim();
      if (name.isNotEmpty) unique.putIfAbsent(name.toLowerCase(), () => name);
    }
    final out = <String, CardInfo>{};
    final wanted = unique.values.toList(growable: false);
    for (var i = 0; i < wanted.length; i += _collectionBatch) {
      final chunk = wanted.skip(i).take(_collectionBatch);
      final j = await _postJson('$_api/cards/collection', {
        'identifiers': [
          for (final name in chunk) {'name': name},
        ],
      });
      // `not_found` identifiers are simply absent from the result; the caller
      // retries those through the fuzzy single-card endpoint.
      final data = j?['data'];
      if (data is! List) continue;
      for (final entry in data) {
        if (entry is! Map) continue;
        final info = cardInfoFromScryfall(entry);
        if (info == null) continue;
        for (final key in _nameKeys(info.name)) {
          out.putIfAbsent(key, () => info);
        }
      }
    }
    return out;
  }

  /// Lookup keys for a card: its full name, plus each face of a split/DFC name
  /// so a list that says "Fire" still matches "Fire // Ice".
  static Iterable<String> _nameKeys(String name) sync* {
    yield name.toLowerCase();
    for (final face in name.split('//')) {
      final key = face.trim().toLowerCase();
      if (key.isNotEmpty) yield key;
    }
  }

  Future<Map<String, dynamic>?> _postJson(String url, Object body) =>
      _throttled(() => _postJsonOnce(url, jsonEncode(body), attempt: 0));

  Future<Map<String, dynamic>?> _postJsonOnce(
    String url,
    String body, {
    required int attempt,
  }) async {
    final req = await _http.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'mtg-tourney/1.0');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.contentType = ContentType.json;
    req.write(body);
    final resp = await req.close();
    if (resp.statusCode == 200) {
      final text = await resp.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    }
    final retryAfter = _retryAfter(resp);
    await resp.drain<void>();
    if (_isTransient(resp.statusCode) && attempt < maxRetries) {
      await Future<void>.delayed(retryAfter ?? _backoff(attempt));
      return _postJsonOnce(url, body, attempt: attempt + 1);
    }
    return null;
  }

  @override
  Future<List<String>> autocomplete(String query) async {
    if (query.trim().length < 2) return const [];
    final j = await _getJson(
      '$_api/cards/autocomplete?q=${Uri.encodeQueryComponent(query.trim())}',
    );
    final data = j?['data'];
    return data is List ? data.cast<String>() : const [];
  }

  @override
  // Image downloads hit the static CDN, not the rate-limited API — so they are
  // NOT throttled/serialised. Callers fire many at once; HttpClient bounds real
  // concurrency via maxConnectionsPerHost. This is the main download speed-up.
  Future<List<int>> fetchImage(String url) => _fetchImageOnce(url, attempt: 0);

  Future<List<int>> _fetchImageOnce(String url, {required int attempt}) async {
    final req = await _http.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'mtg-tourney/1.0');
    final resp = await req.close();
    if (resp.statusCode == 200) {
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
      }
      return bytes;
    }
    final retryAfter = _retryAfter(resp);
    await resp.drain<void>();
    if (_isTransient(resp.statusCode) && attempt < maxRetries) {
      await Future<void>.delayed(retryAfter ?? _backoff(attempt));
      return _fetchImageOnce(url, attempt: attempt + 1);
    }
    throw HttpException('image ${resp.statusCode}', uri: Uri.parse(url));
  }

  static bool _isTransient(int status) =>
      status == 429 || (status >= 500 && status < 600);

  /// Exponential backoff: 400ms, 800ms, 1600ms, …
  Duration _backoff(int attempt) =>
      Duration(milliseconds: 400 * (1 << attempt));

  /// Honour a numeric `Retry-After` header (seconds) when present.
  static Duration? _retryAfter(HttpClientResponse resp) {
    final v = resp.headers.value(HttpHeaders.retryAfterHeader);
    if (v == null) return null;
    final secs = int.tryParse(v.trim());
    return secs == null ? null : Duration(seconds: secs);
  }

  void close() => _http.close(force: true);
}
