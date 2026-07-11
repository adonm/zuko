import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/pairing_code.dart';

void main() {
  test('accepts canonical pairing forms', () {
    expect(PairingCode.parse('iridescent-hilton'), 'iridescent-hilton');
    expect(
      PairingCode.parse('zuko://pair/iridescent-hilton'),
      'iridescent-hilton',
    );
    expect(
      PairingCode.parse('ZUKO://PAIR?CODE=iridescent%2Dhilton'),
      'iridescent-hilton',
    );
    expect(PairingCode.parse('iridescent_hilton'), 'iridescent-hilton');
  });

  test('rejects malformed or command-like input', () {
    expect(PairingCode.parse('zuko://other/a-b'), isNull);
    expect(PairingCode.parse('a-b\nrm -rf'), isNull);
    expect(PairingCode.parse('123-456'), isNull);
    expect(PairingCode.parse('single'), isNull);
  });
}
