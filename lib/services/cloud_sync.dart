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
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;

bool _hasGoogleStatus(Object error, int status) {
  final details = error is PlatformException
      ? '${error.message ?? ''} ${error.details ?? ''}'
      : error.toString();
  return RegExp(
    '(?:ApiException|[\\w.]+)\\s*:\\s*$status\\b',
    caseSensitive: false,
  ).hasMatch(details);
}

/// Turn a raw sign-in error into an honest, actionable message. The most common
/// failure is NOT a network problem: `ApiException: 10` (DEVELOPER_ERROR) means
/// the Google OAuth client / SHA-1 for this app isn't configured yet. Returns ''
/// for a plain user cancel (no message needed).
String cloudErrorMessage(Object error) {
  final code = error is PlatformException ? error.code.toLowerCase() : '';
  final raw = error.toString();
  final normalized = '$code $raw'.toLowerCase();

  if (code == GoogleSignIn.kSignInCanceledError ||
      _hasGoogleStatus(error, 12501) ||
      normalized.contains('sign_in_cancelled') ||
      normalized.contains('sign_in_canceled')) {
    return ''; // User cancelled — nothing to report.
  }

  if (_hasGoogleStatus(error, 10) || normalized.contains('developer_error')) {
    return 'Google sign-in is not configured for this APK. Register package '
        'com.giuseppe.mtg.mtg_tourney and its signing SHA-1 as an Android OAuth '
        'client in Google Cloud, then try again. You can continue as a guest.';
  }

  if (code == GoogleSignIn.kNetworkError ||
      _hasGoogleStatus(error, 7) ||
      normalized.contains('network_error')) {
    return 'Network error reaching Google. Check your connection and try again.';
  }

  if (normalized.contains('accessnotconfigured') ||
      normalized.contains('service_disabled') ||
      normalized.contains('permission_denied') ||
      normalized.contains('drive api has not been used')) {
    return 'Google sign-in succeeded, but Drive backup is unavailable. Enable '
        'the Google Drive API and the drive.appdata scope in the same Google '
        'Cloud project.';
  }

  if (error is FormatException) {
    return 'The Google Drive backup is invalid or incompatible, so local data '
        'was left unchanged.';
  }

  if (code == GoogleSignIn.kSignInFailedError ||
      normalized.contains('apiexception')) {
    return 'Google sign-in failed. Verify the Android OAuth package and signing '
        'SHA-1 configuration, or continue as a guest.';
  }

  return 'Google Drive backup failed. Your local data is unchanged; check your '
      'connection and try again.';
}

/// Cloud-backup boundary used by [DriveCloudSync] in production and by
/// controller fakes in tests.
abstract interface class CloudSync {
  bool get isSignedIn;
  String? get email;
  String? get displayName;

  Future<bool> signInSilently();
  Future<bool> signIn();
  Future<void> signOut();
  Future<String?> download();
  Future<void> upload(String data);
}

class DriveCloudSync implements CloudSync {
  static const _fileName = 'mtg_tourney_backup.json';

  // driveAppdataScope = access ONLY to this app's hidden folder, nothing else in
  // the user's Drive — the least privilege that does the job.
  final GoogleSignIn _gsi = GoogleSignIn(
    scopes: const [drive.DriveApi.driveAppdataScope],
  );

  @override
  bool get isSignedIn => _gsi.currentUser != null;

  @override
  String? get email => _gsi.currentUser?.email;

  @override
  String? get displayName => _gsi.currentUser?.displayName;

  /// Resume a prior session without UI (call at startup). Safe offline: returns
  /// false on any failure.
  @override
  Future<bool> signInSilently() async {
    try {
      return (await _gsi.signInSilently()) != null;
    } catch (_) {
      return false;
    }
  }

  /// Interactive sign-in (shows the Google account picker). Returns true on success.
  @override
  Future<bool> signIn() async {
    final account = await _gsi.signIn(); // null if the user cancels
    return account != null;
  }

  @override
  Future<void> signOut() => _gsi.signOut();

  Future<drive.DriveApi> _api() async {
    final client = await _gsi.authenticatedClient();
    if (client == null) {
      throw StateError('Google Drive authorization was not granted.');
    }
    return drive.DriveApi(client);
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
  @override
  Future<String?> download() async {
    final api = await _api();
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
  @override
  Future<void> upload(String data) async {
    final api = await _api();
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
