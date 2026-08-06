/// Local export / "share with another app" of everything this device stores:
/// profile, decks, card catalog, the live tournament and the whole history.
///
/// Format is gzipped JSON — the same save blob used for Google Drive backup,
/// so an export can be re-imported later, but ~10x smaller on the wire.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

import '../server/controller.dart';

/// Build the shareable blob. Session material (bearer tokens, the active join
/// code) is stripped: an export leaves the device and must never carry
/// credentials that let the receiver act as the organizer or a player.
({String name, Uint8List bytes}) buildExport(
  ServerController server,
  DateTime now,
) {
  final data = server.toJson()
    ..remove('tokens')
    ..remove('ownerToken')
    ..remove('joinCode')
    ..remove('hostingMode')
    // Questionnaire answers are each player's own private report. A shared
    // export goes to someone else, so they never travel in one.
    ..remove('surveys');
  final stamp = now.toIso8601String().split('T').first;
  return (
    name: 'mtg-tourney-$stamp.json.gz',
    // ponytail: gzip is in dart:io — no archive/zip package needed.
    bytes: Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(data)))),
  );
}

/// Open the Android share sheet (Telegram, Gmail, WhatsApp, Files, Drive …).
Future<void> shareExport(ServerController server) async {
  final export = buildExport(server, DateTime.now());
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(export.bytes, mimeType: 'application/gzip')],
      fileNameOverrides: [export.name],
      subject: 'MTG tournament data',
    ),
  );
}
