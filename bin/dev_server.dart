/// Standalone dev server for headless testing on Windows (no device needed):
///   dart run bin/dev_server.dart [port]
/// Serves the player PWA from assets/web and the same REST+WS API the host app
/// uses. Drive it from a browser or Playwright at the printed localhost URL.
library;

import 'dart:io';

import 'package:shelf_static/shelf_static.dart';

import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/server/server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args.first) : 8080;
  final controller = ServerController();
  final staticHandler = createStaticHandler(
    'assets/web',
    defaultDocument: 'index.html',
  );
  await serveController(
    controller,
    port: port,
    staticHandler: staticHandler,
    log: true,
  );
  final ip = await lanIpv4();
  stdout.writeln('── MTG Tournament dev server ──');
  stdout.writeln('  local : http://localhost:$port');
  stdout.writeln('  LAN   : http://$ip:$port');
  stdout.writeln('Open the player client in a browser at the URL above.');
}
