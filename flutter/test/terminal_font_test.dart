import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fonts = {
    'JetBrainsMono-Regular.ttf': [0, 1, 0, 0],
    'JetBrainsMono-Bold.ttf': [0, 1, 0, 0],
    'JetBrainsMonoNerdFontMono-Regular.ttf': [0, 1, 0, 0],
    'NotoSansMono.ttf': [0, 1, 0, 0],
    'NotoEmoji-Regular.ttf': [0, 1, 0, 0],
    'NotoSansSymbols2-Regular.ttf': [0, 1, 0, 0],
    'NotoSansJP-Regular.otf': [0x4f, 0x54, 0x54, 0x4f],
    'NotoSansKR-Regular.otf': [0x4f, 0x54, 0x54, 0x4f],
  };

  for (final MapEntry(key: name, value: signature) in fonts.entries) {
    test('bundles $name as an OpenType font', () async {
      final data = await rootBundle.load('assets/fonts/$name');
      expect(data.lengthInBytes, greaterThan(0));
      expect(data.buffer.asUint8List(0, 4), signature);
    });
  }
}
