import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/host/host_controller.dart';
import 'package:mtg_tourney/services/cloud_sync.dart';
import 'package:mtg_tourney/ui/app_scope.dart';
import 'package:mtg_tourney/ui/host_screen.dart';

class _NoCloud implements CloudSync {
  @override
  String? get displayName => null;

  @override
  String? get email => null;

  @override
  bool get isSignedIn => false;

  @override
  Future<String?> download() async => null;

  @override
  Future<bool> signIn() async => false;

  @override
  Future<bool> signInSilently() async => false;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> upload(String data) async {}
}

void main() {
  testWidgets('tournament creation requires an Online or LAN choice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = HostController(cloud: _NoCloud())..ready = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const HostScreen()),
      ),
    );

    expect(find.text('Online'), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
    expect(
      find.text('Choose how players will connect to this tournament.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Create & open lobby'));
    await tester.pump();

    expect(find.text('Choose Online or LAN hosting.'), findsOneWidget);
  });

  testWidgets('an unconfigured build explains why Online cannot start', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = HostController(cloud: _NoCloud())..ready = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(controller: controller, child: const HostScreen()),
      ),
    );

    await tester.tap(find.text('Online'));
    await tester.pump();

    expect(
      find.textContaining('Online hosting needs a relay URL'),
      findsOneWidget,
    );
    await tester.tap(find.text('Create & open lobby'));
    await tester.pump();
    expect(
      find.text('Online hosting is not configured in this app build.'),
      findsOneWidget,
    );
  });
}
