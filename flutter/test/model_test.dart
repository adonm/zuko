import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/model.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (index) => index));

  test('version 1 state loads with backwards-compatible preferences', () {
    final state = ClientState.decode(
      jsonEncode({
        'version': 1,
        'clientKey': base64Encode(key),
        'hosts': [
          {
            'name': 'home',
            'label': 'server',
            'ticket': 'ticket',
            'nodeId': 'node',
          },
        ],
      }),
    );

    expect(state.theme, AppThemePreference.system);
    expect(state.terminalFontSize, 14);
    expect(state.showAdditionalKeys, isTrue);
    expect(state.hosts.single.authorizedClientLabel, isNull);
  });

  test('current state round-trips preferences and exact client label', () {
    final original = ClientState(
      clientKey: key,
      theme: AppThemePreference.light,
      terminalFontSize: 17,
      showAdditionalKeys: false,
      hosts: const [
        SavedHost(
          name: 'home',
          label: 'server',
          ticket: 'ticket',
          nodeId: 'node',
          authorizedClientLabel: 'zuko-android-a1b2c3',
        ),
      ],
    );

    final decoded = ClientState.decode(original.encode());
    expect(decoded.theme, AppThemePreference.light);
    expect(decoded.terminalFontSize, 17);
    expect(decoded.showAdditionalKeys, isFalse);
    expect(decoded.hosts.single.authorizedClientLabel, 'zuko-android-a1b2c3');
  });

  test('rejects unsupported and structurally invalid state', () {
    expect(
      () => ClientState.decode('{"version":99}'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ClientState.decode(
        jsonEncode({
          'version': ClientState.currentVersion,
          'clientKey': base64Encode(key),
          'hosts': 'not-a-list',
          'showAdditionalKeys': true,
        }),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('terminal font size rejects invalid values and stays practical', () {
    expect(normalizeTerminalFontSize(double.nan), 14);
    expect(normalizeTerminalFontSize(2), 10);
    expect(normalizeTerminalFontSize(40), 24);
  });
}
