import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/host/host_controller.dart';
import 'package:mtg_tourney/services/cloud_sync.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a deck profile picture is stored, replaced and removed', () async {
    final c = HostController(cloud: _NoCloud());
    addTearDown(c.dispose);
    await c.init();

    expect(c.deckAvatar('deck-1'), isNull);

    await c.setDeckAvatar('deck-1', const [1, 2, 3]);
    expect(c.deckAvatar('deck-1')!.readAsBytesSync(), const [1, 2, 3]);
    expect(c.deckAvatar('deck-2'), isNull, reason: 'pictures are per deck');

    await c.setDeckAvatar('deck-1', const [9]);
    expect(c.deckAvatar('deck-1')!.readAsBytesSync(), const [9]);

    await c.setDeckAvatar('deck-1', null);
    expect(c.deckAvatar('deck-1'), isNull);
  });
}
