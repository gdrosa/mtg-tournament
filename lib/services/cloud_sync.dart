/// Optional Google account cloud backup.
///
/// Signs the user in with Google and stores the app's single JSON save-blob in a
/// PRIVATE per-app folder in their own Google Drive (`appDataFolder` — invisible
/// in the normal Drive UI, only this app can read it). This is the unit of
/// backup/restore so a reinstall can re-fetch everything by signing in again.
///
/// Only ever called at app-start / explicit sync — never on a tournament path —
/// so the offline-first guarantee (NFR-13/14) holds during an event.
library;

import 'dart:convert';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

/// Turn a raw sign-in error into an honest, actionable message. The most common
/// failure is NOT a network problem: `ApiException: 10` (DEVELOPER_ERROR) means
/// the Google OAuth client / SHA-1 for this app isn't configured yet. Returns ''
/// for a plain user cancel (no message needed).
String cloudErrorMessage(Object e) {
  final s = e.toString();
  if (s.contains('ApiException: 10') ||
      s.contains('DEVELOPER_ERROR') ||
      s.contains(': 10,')) {
    return 'Google sign-in isn\'t set up for this app yet (its OAuth client / SHA-1 in '
        'Google Cloud). This is NOT a connection problem — finish that one-time setup, '
        'or use the app as a guest.';
  }
  if (s.contains('ApiException: 7') || s.contains('NETWORK_ERROR')) {
    return 'Network error reaching Google. Check your connection and try again.';
  }
  if (s.contains('12501') ||
      s.contains('SIGN_IN_CANCELLED') ||
      s.toLowerCase().contains('cancel')) {
    return ''; // user cancelled — nothing to report
  }
  if (s.contains('ApiException')) {
    return 'Google sign-in failed ($s). It may be the OAuth setup; you can continue as guest.';
  }
  return 'Couldn\'t sign in: $s';
}

class DriveCloudSync {
  static const _fileName = 'mtg_tourney_backup.json';

  // driveAppdataScope = access ONLY to this app's hidden folder, nothing else in
  // the user's Drive — the least privilege that does the job.
  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: const [drive.DriveApi.driveAppdataScope],
  );

  bool get isSignedIn => _gsi.currentUser != null;
  String? get email => _gsi.currentUser?.email;
  String? get displayName => _gsi.currentUser?.displayName;

  /// Resume a prior session without UI (call at startup). Safe offline: returns
  /// false on any failure.
  Future<bool> signInSilently() async {
    try {
      return (await _gsi.signInSilently()) != null;
    } catch (_) {
      return false;
    }
  }

  /// Interactive sign-in (shows the Google account picker). Returns true on success.
  Future<bool> signIn() async {
    final account = await _gsi.signIn(); // null if the user cancels
    return account != null;
  }

  Future<void> signOut() => _gsi.signOut();

  Future<drive.DriveApi?> _api() async {
    final client = await _gsi.authenticatedClient();
    return client == null ? null : drive.DriveApi(client);
  }

  Future<String?> _backupFileId(drive.DriveApi api) async {
    final res = await api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$_fileName'",
      $fields: 'files(id, modifiedTime)',
    );
    final files = res.files;
    return (files != null && files.isNotEmpty) ? files.first.id : null;
  }

  /// Download the saved blob, or null if the account has no backup yet.
  Future<String?> download() async {
    final api = await _api();
    if (api == null) return null;
    final id = await _backupFileId(api);
    if (id == null) return null;
    final media =
        await api.files.get(
              id,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  /// Create or overwrite the backup blob (last-write-wins).
  // ponytail: last-write-wins is fine for one primary device; add a modifiedTime
  // merge only if multi-device editing becomes a real use case.
  Future<void> upload(String data) async {
    final api = await _api();
    if (api == null) return;
    final bytes = utf8.encode(data);
    final media = drive.Media(
      Stream.value(bytes),
      bytes.length,
      contentType: 'application/json',
    );
    final existing = await _backupFileId(api);
    if (existing == null) {
      final meta = drive.File()
        ..name = _fileName
        ..parents = ['appDataFolder'];
      await api.files.create(meta, uploadMedia: media);
    } else {
      await api.files.update(drive.File(), existing, uploadMedia: media);
    }
  }
}
