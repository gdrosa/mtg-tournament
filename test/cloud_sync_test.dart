import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/services/cloud_sync.dart';

void main() {
  group('cloudErrorMessage', () {
    test('recognizes obfuscated Google Play services status 10', () {
      final error = PlatformException(
        code: 'sign_in_failed',
        message: 'j1.d: 10: ',
      );

      final message = cloudErrorMessage(error);

      expect(message, contains('Android OAuth'));
      expect(message, contains('SHA-1'));
      expect(message, isNot(contains('PlatformException')));
    });

    test('recognizes obfuscated network status 7', () {
      final error = PlatformException(
        code: 'network_error',
        message: 'j1.d: 7: ',
      );

      expect(cloudErrorMessage(error), contains('Network error'));
    });

    test('returns no message when the account picker is cancelled', () {
      final error = PlatformException(code: 'sign_in_canceled');

      expect(cloudErrorMessage(error), isEmpty);
    });

    test('does not expose an invalid cloud backup as a raw exception', () {
      final message = cloudErrorMessage(
        const FormatException('Invalid Google Drive backup.'),
      );

      expect(message, contains('local data was left unchanged'));
      expect(message, isNot(contains('FormatException')));
    });
  });
}
