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

  test('extract finds a code inside free-form pasted text', () {
    expect(PairingCode.extract('iridescent-hilton'), 'iridescent-hilton');
    expect(
      PairingCode.extract('zuko claim iridescent-hilton'),
      'iridescent-hilton',
    );
    expect(
      PairingCode.extract(
        'on the other machine:\n  zuko claim IRIDESCENT-HILTON',
      ),
      'iridescent-hilton',
    );
    expect(
      PairingCode.extract(
        'share this code (serves 1, then exits):\niridescent-hilton\n'
        'scan with the Zuko iOS app:\n  on the other machine:\n'
        '    zuko claim iridescent-hilton',
      ),
      'iridescent-hilton',
    );
    expect(
      PairingCode.extract(
        'pair with https://zuko.dev zuko://pair/azure-quokka',
      ),
      'azure-quokka',
    );
    expect(
      PairingCode.extract('the code: iridescent hilton (expires soon)'),
      'iridescent-hilton',
    );
  });

  test('extract prefers a real code over prose or rejects prose', () {
    expect(
      PairingCode.extract('scan with the Zuko iOS app'),
      isNull,
      reason: 'prose must not be mistaken for a code',
    );
    expect(PairingCode.extract('run zuko on linux first'), isNull);
    expect(
      PairingCode.extract(
        'share this code (serves 1, then exits):\n'
        'scan with the Zuko iOS app:\niridescent-hilton',
      ),
      'iridescent-hilton',
    );
    expect(
      PairingCode.extract('zuko claim azure-quokka zuko claim blue-badger'),
      'azure-quokka',
    );
  });
}
