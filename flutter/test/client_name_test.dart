import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/client_name.dart';

void main() {
  test('normalizes friendly names into safe compact labels', () {
    expect(normalizeClientName('  Office iPad  '), 'office-ipad');
    expect(normalizeClientName('Pixel_9 / Personal'), 'pixel-9-personal');
    expect(normalizeClientName('Étage 東京'), 'étage-東京');
    expect(normalizeClientName('---'), isEmpty);
    expect(
      normalizeClientName('a' * (maxClientNameLength + 10)),
      'a' * maxClientNameLength,
    );
  });

  test('automatic names skip generic device values', () {
    expect(
      firstUsableClientName([
        null,
        'unknown',
        'Android',
        'Google Pixel 9',
      ], fallback: 'android-device'),
      'google-pixel-9',
    );
    expect(
      firstUsableClientName(['localhost'], fallback: 'Linux PC'),
      'linux-pc',
    );
  });

  test('authorization label retains the identity-derived suffix', () {
    final key = Uint8List.fromList(List.generate(32, (index) => index));

    expect(
      clientAuthorizationLabel('Office iPad', key),
      'zuko-office-ipad-000102',
    );
  });
}
