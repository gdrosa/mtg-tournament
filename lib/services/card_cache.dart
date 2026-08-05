/// On-device cache of Scryfall card images.
///
/// Images live as `<scryfallId>.jpg` under [dir] (inside the app's documents
/// dir). The host's Flutter UI reads them with `Image.file`; the embedded server
/// serves the same directory over the LAN (`GET /cards/img/<id>`) so browser
/// players see images **offline**, from cache only.
library;

import 'dart:io';

class CardImageCache {
  final Directory dir;
  CardImageCache(this.dir);

  File fileFor(String cardId) =>
      File('${dir.path}${Platform.pathSeparator}$cardId.jpg');

  bool isCached(String cardId) => fileFor(cardId).existsSync();

  /// Write [bytes] for [cardId], creating the cache dir on first use.
  Future<void> store(String cardId, List<int> bytes) async {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('${fileFor(cardId).path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(fileFor(cardId).path);
  }

  /// Cached card ids currently on disk.
  Set<String> cachedIds() {
    if (!dir.existsSync()) return {};
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg'))
        .map((f) => f.uri.pathSegments.last.replaceAll('.jpg', ''))
        .toSet();
  }
}
