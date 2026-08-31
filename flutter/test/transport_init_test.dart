import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/transport_native.dart';

/// Guards the production transport bootstrap: `createClientTransport`
/// initialises the irohdart-ffi native library and enforces the
/// flutter_rust_bridge codegen-version handshake plus the iroh ABI check.
///
/// Pairing and every terminal connection go through this path, but the
/// integration suite runs against LocalHostTransport and never calls it —
/// a broken or mismatched native library used to ship unnoticed (an
/// IrohLoadException here is exactly the 0.12.5 "can't pair or connect"
/// failure). This test fails the suite the moment Iroh can no longer
/// initialise, so the release gate catches any codegen/ABI drift or a
/// missing prebuilt library.
void main() {
  test('iroh transport initialises against the native library', () async {
    final clientKey = Uint8List.fromList(
      List<int>.generate(32, (index) => index + 1),
    );
    final transport = await createClientTransport(clientKey);
    addTearDown(transport.close);
  });
}
