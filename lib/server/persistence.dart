/// Durable storage for the controller's full state (crash-resume).
///
/// PURE DART (dart:io): works on-device and on Windows for tests. We snapshot
/// the whole state as JSON on every accepted mutation (persist-then-broadcast);
/// the state is tiny, so a synchronous atomic write per event is cheap.
library;

import 'dart:io';

abstract class Persistence {
  /// Durably write [data], replacing any previous snapshot.
  void save(String data);

  /// Read the last snapshot, or null if none/empty.
  String? load();
}

/// Atomic file persistence: write to a temp file then rename over the target,
/// so a crash mid-write can never corrupt the saved tournament.
class FilePersistence implements Persistence {
  final String path;
  FilePersistence(this.path);

  @override
  void save(String data) {
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(data, flush: true);
    tmp.renameSync(path);
  }

  @override
  String? load() {
    final f = File(path);
    if (!f.existsSync()) return null;
    final s = f.readAsStringSync();
    return s.isEmpty ? null : s;
  }
}

/// In-memory persistence for unit tests.
class MemoryPersistence implements Persistence {
  String? data;
  @override
  void save(String d) => data = d;
  @override
  String? load() => data;
}
