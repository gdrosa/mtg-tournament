/// "Is there a newer stable release?" check against the project's GitHub
/// releases, plus the dialog that asks the organizer before installing it.
///
/// STABLE ONLY: GitHub's `releases/latest` endpoint already skips drafts and
/// pre-releases, and [releaseFromJson] rejects them again in case the payload
/// ever comes from somewhere else. Nightlies are never offered.
///
/// The app does not install anything itself — tapping "Update" opens the APK
/// in the browser and Android's own package installer takes over, so the user
/// grants permission twice (here, then to the system).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _latestReleaseApi =
    'https://api.github.com/repos/gdrosa/mtg-tournament/releases/latest';

/// A published stable release we could install.
class AppRelease {
  /// "0.0.3" — the tag with any leading "v" removed.
  final String version;

  /// The direct .apk asset when the release has one, else the release page.
  final String url;

  const AppRelease({required this.version, required this.url});
}

/// True when [candidate] is a higher version than [installed]. Both are dotted
/// numbers; a leading "v" and a "+build" suffix are ignored.
bool isNewerVersion(String candidate, String installed) {
  List<int> parts(String v) => v
      .trim()
      .replaceFirst(RegExp('^v', caseSensitive: false), '')
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();

  final a = parts(candidate);
  final b = parts(installed);
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false; // same version, or older
}

/// Read a GitHub release object. Returns null for a draft, a pre-release, or
/// anything without a usable tag.
AppRelease? releaseFromJson(Map json) {
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = (json['tag_name'] as String?)?.trim() ?? '';
  if (tag.isEmpty) return null;

  String? apk;
  final assets = json['assets'];
  if (assets is List) {
    for (final a in assets) {
      final url = a is Map ? a['browser_download_url'] : null;
      if (url is String && url.toLowerCase().endsWith('.apk')) {
        apk = url;
        break;
      }
    }
  }
  final page = (json['html_url'] as String?) ?? '';
  final url = apk ?? page;
  if (url.isEmpty) return null;

  return AppRelease(
    version: tag.replaceFirst(RegExp('^v', caseSensitive: false), ''),
    url: url,
  );
}

/// Fetch the newest stable release, or null when offline / rate-limited.
Future<AppRelease?> fetchLatestStableRelease() async {
  // ponytail: one throwaway HttpClient per check — this runs once a launch.
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await http.getUrl(Uri.parse(_latestReleaseApi));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    req.headers.set(HttpHeaders.userAgentHeader, 'mtg-tourney-app');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body);
    return json is Map ? releaseFromJson(json) : null;
  } catch (_) {
    return null; // offline is the normal case at a venue, not an error
  } finally {
    http.close(force: true);
  }
}

/// Check for a newer stable release and offer it. Silent when there is nothing
/// to offer (launch check); [silent] false also reports "up to date" and
/// failures, for the manual button in Profile.
Future<void> checkForUpdate(BuildContext context, {bool silent = true}) async {
  // Runs unattended at launch: a plugin miss must never take the app down.
  String installed;
  try {
    installed = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return;
  }
  final release = await fetchLatestStableRelease();
  if (!context.mounted) return;

  if (release == null || !isNewerVersion(release.version, installed)) {
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            release == null
                ? 'Could not check for updates.'
                : 'You are on the latest version ($installed).',
          ),
        ),
      );
    }
    return;
  }

  final accepted = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Update to ${release.version}?'),
      content: Text(
        'You have $installed. Tapping Update downloads the new APK and hands '
        'it to Android to install — your tournaments and decks are kept.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Update'),
        ),
      ],
    ),
  );
  if (accepted != true || !context.mounted) return;

  final opened = await launchUrl(
    Uri.parse(release.url),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not open ${release.url}')));
  }
}
