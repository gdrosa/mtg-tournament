/// Sharing and receiving interchange bundles from the host UI.
///
/// The merge rules live in `server/interchange.dart`; this file only moves
/// bytes — out through the Android share sheet, in from a picked file or the
/// clipboard. Exports are files, so opening a file is the path that closes the
/// loop; the clipboard stays for a bundle pasted into a chat.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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
  String? raw, {
  String emptyMessage = 'The clipboard is empty. Copy the shared bundle first.',
}) {
  if (raw == null || raw.trim().isEmpty) {
    return (bundle: null, preview: ImportPreview.error(emptyMessage));
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

/// Ask for a file and report what importing it would change. Returns null when
/// the picker is dismissed, which must not be reported as a failure.
Future<({Map<String, dynamic>? bundle, ImportPreview preview})?>
previewFileBundle(ServerController c) async {
  // The share sheet writes .json, but a bundle mailed around can arrive as
  // .txt or with no extension at all, so the filter stays wide.
  const types = [
    XTypeGroup(
      label: 'Tournament data',
      extensions: ['json', 'txt'],
      mimeTypes: ['application/json', 'text/plain'],
    ),
  ];
  final file = await openFile(acceptedTypeGroups: types);
  if (file == null) return null;
  String? text;
  try {
    text = await file.readAsString();
  } catch (_) {
    return (
      bundle: null,
      preview: ImportPreview.error('That file could not be read.'),
    );
  }
  return inspectBundleText(c, text, emptyMessage: 'That file is empty.');
}

/// Apply a bundle. Additive and idempotent — see [mergeBundle].
ImportResult importBundleText(
  ServerController c,
  Map<String, dynamic> bundle, {
  Map<String, String> identityMap = const {},
}) => mergeBundle(c, bundle, identityMap: identityMap);
