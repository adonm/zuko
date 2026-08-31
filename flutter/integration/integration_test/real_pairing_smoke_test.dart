import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/transport_native.dart';

/// Real pairing smoke test against a running host: run `zuko host` and
/// `zuko share` on this machine, pass the printed two-word code as
/// ZUKO_PAIRING_CODE, and this drives the production iroh_flutter transport
/// through the actual claim handshake over the iroh relay network.
///
/// Skipped without the define so the CI suite stays hermetic.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('claim a real host ticket over iroh', (tester) async {
    const code = String.fromEnvironment('ZUKO_PAIRING_CODE');
    if (code.isEmpty) {
      markTestSkipped('no ZUKO_PAIRING_CODE define; run with a live host');
      return;
    }

    final clientKey = Uint8List.fromList(
      List<int>.generate(32, (index) => index + 7),
    );
    final transport = await createClientTransport(clientKey);
    addTearDown(transport.close);

    final result = await transport.claim(code, 'zuko-smoke-test-client');
    expect(result.label, isNotEmpty);
    expect(result.ticket, isNotEmpty);
    expect(result.nodeId, hasLength(64));
    // The host now has this client authorised; connecting is covered by the
    // regular session path in app_interactions_test.
  });
}
