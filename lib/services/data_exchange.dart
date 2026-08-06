/// Sharing and receiving interchange bundles from the host UI.
///
/// The merge rules live in `server/interchange.dart`; this file only moves
/// bytes — out through the Android share sheet, in through the clipboard.
///
/// ponytail: no file-picker dependency. `file_picker` needs win32 ^5.9 while
/// the `share_plus` already in this app needs ^6.0, so the two cannot coexist;
/// rather than downgrade a working share path, importing reads the clipboard,
/// which covers the "someone sent me their tournament" case. Swap in a picker
/// the day that constraint clears — [importBundleText] is the seam.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pasteboard/pasteboard.dart';
import 'package:share_plus/share_plus.dart';

import '../server/controller.dart';
import '../server/interchange.dart';
import '../shared/stats_facts.dart';

/// Share an interchange bundle as a `.json` file.
Future<void> shareBundle(
  ServerController c, {
  required BundleScope scope,
  String? tournamentId,
  String? playerId,
  String filenameHint = 'data',
}) async {
  final bundle = buildBundle(
    c,
    scope: scope,
    tournamentId: tournamentId,
    playerId: playerId,
  );
  await _shareText(
    encodeBundle(bundle),
    'mtg-$filenameHint-${_stamp(c)}.json',
    'application/json',
    'MTG tournament data',
  );
}

/// Share anonymized aggregate statistics — no ids, no names, no decklists.
Future<void> shareAggregate(
  ServerController c, {
  StatFilter filter = const StatFilter(),
}) => _shareText(
  const JsonEncoder.withIndent(
    '  ',
  ).convert(buildAggregateExport(c, filter: filter)),
  'mtg-aggregate-${_stamp(c)}.json',
  'application/json',
  'MTG aggregate statistics',
);

/// Share a CSV. [csv] comes from `interchange.dart`'s builders.
Future<void> shareCsv(String csv, String name) =>
    _shareText(csv, name, 'text/csv', 'MTG tournament export');

String _stamp(ServerController c) =>
    c.clock().toIso8601String().split('T').first;

Future<void> _shareText(
  String body,
  String filename,
  String mime,
  String subject,
) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(Uint8List.fromList(utf8.encode(body)), mimeType: mime),
      ],
      fileNameOverrides: [filename],
      subject: subject,
    ),
  );
}

/// What the clipboard currently holds, if it is a readable bundle.
///
/// Returns the parsed bundle plus a preview of what importing it would do, or
/// an [ImportPreview] carrying the reason it cannot be used.
({Map<String, dynamic>? bundle, ImportPreview preview}) inspectBundleText(
  ServerController c,
  String? raw,
) {
  if (raw == null || raw.trim().isEmpty) {
    return (
      bundle: null,
      preview: ImportPreview.error(
        'The clipboard is empty. Copy the shared bundle first.',
      ),
    );
  }
  final decoded = decodeBundle(raw);
  if (decoded == null) {
    return (
      bundle: null,
      preview: ImportPreview.error('That is not tournament data.'),
    );
  }
  return (bundle: decoded, preview: previewBundle(c, decoded));
}

/// Read the clipboard and report what importing it would change. Nothing is
/// applied until [importBundleText] is called with the same text.
Future<({Map<String, dynamic>? bundle, ImportPreview preview})>
previewClipboardBundle(ServerController c) async {
  String? text;
  try {
    text = await Pasteboard.text;
  } catch (_) {
    text = null;
  }
  return inspectBundleText(c, text);
}

/// Apply a bundle. Additive and idempotent — see [mergeBundle].
ImportResult importBundleText(
  ServerController c,
  Map<String, dynamic> bundle, {
  Map<String, String> identityMap = const {},
}) => mergeBundle(c, bundle, identityMap: identityMap);
