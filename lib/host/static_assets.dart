/// Extracts the bundled vanilla-JS PWA (assets/web/) to a temp directory so
/// shelf_static can serve it to LAN browsers. Flutter-only (rootBundle).
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

const _webFiles = ['index.html', 'app.js', 'style.css', 'app_logo.png'];

/// Copies the web client out of the APK to a servable directory; returns its path.
Future<String> extractWebAssets() async {
  final base = await getTemporaryDirectory();
  final webDir = Directory('${base.path}/mtg_web')..createSync(recursive: true);
  for (final name in _webFiles) {
    final data = await rootBundle.load('assets/web/$name');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await File('${webDir.path}/$name').writeAsBytes(bytes, flush: true);
  }
  return webDir.path;
}
