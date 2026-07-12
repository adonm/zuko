import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/storage.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (index) => index));

  test('migrates the version 1 key and removes only that key', () async {
    final storage = _MemoryStorage({
      'zuko-client-state-v1': jsonEncode({
        'version': 1,
        'clientKey': base64Encode(key),
        'hosts': <Object?>[],
      }),
      'unrelated': 'preserve-me',
    });
    final store = ClientStateStore.withStorage(storage);

    final state = await store.load();

    expect(state.clientKey, key);
    expect(storage.values['zuko-client-state-v1'], isNull);
    expect(storage.values['zuko-client-state-v4'], isNotNull);
    expect(storage.values['unrelated'], 'preserve-me');
    expect(store.recoveredInvalidState, isFalse);
  });

  test('migrates version 3 preferences without losing client state', () async {
    final storage = _MemoryStorage({
      'zuko-client-state-v3': jsonEncode({
        'version': 3,
        'clientKey': base64Encode(key),
        'hosts': <Object?>[],
        'theme': AppThemePreference.dark.name,
        'terminalFontSize': 17,
        'showAdditionalKeys': false,
      }),
      'unrelated': 'preserve-me',
    });
    final store = ClientStateStore.withStorage(storage);

    final state = await store.load();

    expect(state.clientKey, key);
    expect(state.theme, AppThemePreference.dark);
    expect(state.terminalFontSize, 17);
    expect(state.terminalFontSizeCustomized, isTrue);
    expect(state.showAdditionalKeys, isFalse);
    expect(storage.values['zuko-client-state-v3'], isNull);
    expect(storage.values['zuko-client-state-v4'], isNotNull);
    expect(storage.values['unrelated'], 'preserve-me');
  });

  test('invalid state resets only Zuko state', () async {
    final storage = _MemoryStorage({
      'zuko-client-state-v3': '{broken',
      'zuko-client-state-v1': 'stale',
      'unrelated': 'preserve-me',
    });
    final store = ClientStateStore.withStorage(storage);

    final state = await store.load();

    expect(state.clientKey, hasLength(32));
    expect(state.hosts, isEmpty);
    expect(storage.values['zuko-client-state-v1'], isNull);
    expect(
      ClientState.decode(storage.values['zuko-client-state-v4']!),
      isA<ClientState>(),
    );
    expect(storage.values['unrelated'], 'preserve-me');
    expect(store.recoveredInvalidState, isTrue);
  });
}

final class _MemoryStorage implements SecureStateStorage {
  _MemoryStorage(Map<String, String> values) : values = Map.of(values);

  final Map<String, String> values;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
