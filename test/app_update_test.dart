import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/services/app_update.dart';

/// Shape of a GitHub `releases/latest` payload, trimmed to what we read.
Map<String, dynamic> release({
  String tag = 'v0.0.3',
  bool prerelease = false,
  bool draft = false,
  List<String> assets = const [
    'https://github.com/gdrosa/mtg-tournament/releases/download/v0.0.3/'
        'MTG-Tournament-v0.0.3.apk.sha256',
    'https://github.com/gdrosa/mtg-tournament/releases/download/v0.0.3/'
        'MTG-Tournament-v0.0.3.apk',
  ],
}) => {
  'tag_name': tag,
  'prerelease': prerelease,
  'draft': draft,
  'html_url': 'https://github.com/gdrosa/mtg-tournament/releases/tag/$tag',
  'assets': [
    for (final a in assets) {'browser_download_url': a},
  ],
};

void main() {
  group('isNewerVersion', () {
    test('offers a higher version only', () {
      expect(isNewerVersion('0.0.3', '0.0.2'), isTrue);
      expect(isNewerVersion('0.1.0', '0.0.9'), isTrue);
      expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
      expect(isNewerVersion('0.0.2', '0.0.2'), isFalse);
      expect(isNewerVersion('0.0.1', '0.0.2'), isFalse);
      expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    });

    test('compares numerically, not as strings', () {
      expect(isNewerVersion('0.0.10', '0.0.9'), isTrue);
      expect(isNewerVersion('0.0.9', '0.0.10'), isFalse);
    });

    test('ignores a leading v and a +build suffix', () {
      expect(isNewerVersion('v0.0.3', '0.0.2+2'), isTrue);
      expect(isNewerVersion('V0.0.2', '0.0.2+7'), isFalse);
    });

    test('treats a missing segment as zero', () {
      expect(isNewerVersion('0.1', '0.0.9'), isTrue);
      expect(isNewerVersion('0.0.2', '0.0.2.0'), isFalse);
    });
  });

  group('releaseFromJson', () {
    test('takes the .apk asset over the release page', () {
      final r = releaseFromJson(release())!;
      expect(r.version, '0.0.3');
      expect(r.url, endsWith('MTG-Tournament-v0.0.3.apk'));
    });

    test('never offers a pre-release or a draft', () {
      expect(releaseFromJson(release(prerelease: true)), isNull);
      expect(releaseFromJson(release(draft: true)), isNull);
      expect(
        releaseFromJson(release(tag: 'v0.1.0-nightly', prerelease: true)),
        isNull,
      );
    });

    test('falls back to the release page when there is no APK', () {
      final r = releaseFromJson(release(assets: const []))!;
      expect(r.url, endsWith('/releases/tag/v0.0.3'));
    });

    test('rejects a payload with no tag', () {
      expect(releaseFromJson(release(tag: '')), isNull);
      expect(releaseFromJson(const {}), isNull);
    });
  });
}
