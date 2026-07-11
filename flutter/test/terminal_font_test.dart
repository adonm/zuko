import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final name in [
    'JetBrainsMono-Regular.ttf',
    'JetBrainsMono-Bold.ttf',
    'NotoSansMono.ttf',
    'NotoEmoji-Regular.ttf',
    'NotoSansSymbols2-Regular.ttf',
  ]) {
    test('bundles $name as a TrueType font', () async {
      final data = await rootBundle.load('assets/fonts/$name');
      expect(data.lengthInBytes, greaterThan(0));
      expect(data.buffer.asUint8List(0, 4), [0, 1, 0, 0]);
    });
  }
}
