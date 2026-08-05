import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/host/host_controller.dart';
import 'package:mtg_tourney/server/controller.dart';
import 'package:mtg_tourney/services/cloud_sync.dart';

class _FakeCloudSync implements CloudSync {
  _FakeCloudSync({this.displayName, this.remote});

  @override
  final String? displayName;
  String? remote;
  final List<String> uploads = [];
  bool signedIn = false;

  @override
  String? get email => 'player@example.com';

  @override
  bool get isSignedIn => signedIn;

  @override
  Future<String?> download() async => remote;

  @override
  Future<bool> signIn() async {
    signedIn = true;
    return true;
  }

  @override
  Future<bool> signInSilently() async => false;

  @override
  Future<void> signOut() async {
    signedIn = false;
  }

  @override
  Future<void> upload(String data) async {
    uploads.add(data);
    remote = data;
  }
}

void main() {
  test(
    'first Google sign-in uses the profile name before initial backup',
    () async {
      final cloud = _FakeCloudSync(displayName: '  Giuseppe De Rosa  ');
      final controller = HostController(cloud: cloud);

      expect(await controller.signInToCloud(), isTrue);
      expect(controller.server.owner?.nickname, 'Giuseppe De Rosa');
      expect(cloud.uploads, hasLength(1));

      final uploaded = jsonDecode(cloud.uploads.single) as Map<String, dynamic>;
      final ownerId = uploaded['ownerPlayerId'] as String;
      final players = uploaded['players'] as List<dynamic>;
      final owner = players.cast<Map<String, dynamic>>().singleWhere(
        (player) => player['id'] == ownerId,
      );
      expect(owner['nickname'], 'Giuseppe De Rosa');

      controller.dispose();
    },
  );

  test('an existing cloud profile keeps its custom nickname', () async {
    final remote = ServerController();
    remote.ensureOwner('Planeswalker');
    final cloud = _FakeCloudSync(
      displayName: 'Giuseppe De Rosa',
      remote: remote.exportJson(),
    );
    final controller = HostController(cloud: cloud);

    expect(await controller.signInToCloud(), isTrue);
    expect(controller.server.owner?.nickname, 'Planeswalker');
    expect(cloud.uploads, isEmpty);

    controller.dispose();
  });

  test('an ownerless cloud backup is repaired with the Google name', () async {
    final cloud = _FakeCloudSync(
      displayName: 'Giuseppe De Rosa',
      remote: ServerController().exportJson(),
    );
    final controller = HostController(cloud: cloud);

    expect(await controller.signInToCloud(), isTrue);
    expect(controller.server.owner?.nickname, 'Giuseppe De Rosa');
    expect(cloud.uploads, hasLength(1));

    controller.dispose();
  });

  test('a local custom nickname is preserved when creating a backup', () async {
    final cloud = _FakeCloudSync(displayName: 'Giuseppe De Rosa');
    final controller = HostController(cloud: cloud);
    controller.server.ensureOwner('Local nickname');

    expect(await controller.signInToCloud(), isTrue);
    expect(controller.server.owner?.nickname, 'Local nickname');
    expect(cloud.uploads, hasLength(1));

    controller.dispose();
  });

  test(
    'a blank Google display name does not create an empty profile',
    () async {
      final cloud = _FakeCloudSync(displayName: '   ');
      final controller = HostController(cloud: cloud);

      expect(await controller.signInToCloud(), isTrue);
      expect(controller.server.owner, isNull);
      expect(cloud.uploads, hasLength(1));

      controller.dispose();
    },
  );

  test('an invalid backup fails before applying the Google name', () async {
    final cloud = _FakeCloudSync(
      displayName: 'Giuseppe De Rosa',
      remote: 'not valid JSON',
    );
    final controller = HostController(cloud: cloud);

    await expectLater(
      controller.signInToCloud(),
      throwsA(isA<FormatException>()),
    );
    expect(controller.server.owner, isNull);
    expect(cloud.uploads, isEmpty);
    expect(cloud.isSignedIn, isFalse);

    controller.dispose();
  });
}
