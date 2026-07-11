import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/identity.dart';

void main() {
  test(
    'handoff KDF matches the Rust and Swift fixture',
    () {
      expect(
        deriveHandoffKey(
          'iridescent-hilton',
        ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        '5283f4c14afcfab63641cd2e4961e9318889dee8ce65078b56d37d824118808e',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
