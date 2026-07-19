import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
    expect(storage.values['zuko-client-state-v6'], isNotNull);
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
    expect(storage.values['zuko-client-state-v6'], isNotNull);
    expect(storage.values['unrelated'], 'preserve-me');
  });

  test('migrates the previous current state key', () async {
    final storage = _MemoryStorage({
      'zuko-client-state-v5': jsonEncode({
        'version': 5,
        'clientKey': base64Encode(key),
        'hosts': <Object?>[],
        'clientName': 'office-laptop',
        'theme': AppThemePreference.system.name,
        'terminalFontSize': 10,
        'terminalFontSizeCustomized': false,
        'showAdditionalKeys': true,
      }),
    });
    final store = ClientStateStore.withStorage(storage);

    final state = await store.load();

    expect(state.clientKey, key);
    expect(state.clientName, 'office-laptop');
    expect(state.interfaceSize, AppInterfaceSize.standard);
    expect(storage.values['zuko-client-state-v5'], isNull);
    expect(storage.values['zuko-client-state-v6'], isNotNull);
  });

  test(
    'current client identity and saved hosts survive repeated loads',
    () async {
      final storage = _MemoryStorage({});
      final firstStore = ClientStateStore.withStorage(storage);
      final created = await firstStore.load();
      final saved = created.copyWith(
        clientName: 'office-laptop',
        interfaceSize: AppInterfaceSize.comfortable,
        hosts: const [
          SavedHost(
            name: 'Home',
            label: 'home',
            ticket: 'ticket',
            nodeId: 'node',
            authorizedClientLabel: 'zuko-linux-a1b2c3',
          ),
        ],
      );
      await firstStore.save(saved);

      final reopened = await ClientStateStore.withStorage(storage).load();

      expect(reopened.clientKey, saved.clientKey);
      expect(reopened.clientName, 'office-laptop');
      expect(reopened.interfaceSize, AppInterfaceSize.comfortable);
      expect(reopened.hosts.single.nodeId, 'node');
      expect(reopened.hosts.single.authorizedClientLabel, 'zuko-linux-a1b2c3');
    },
  );

  test('invalid state resets only Zuko state', () async {
    final storage = _MemoryStorage({
      'zuko-client-state-v5': '{broken',
      'zuko-client-state-v4': 'stale',
      'zuko-client-state-v3': 'stale',
      'zuko-client-state-v1': 'stale',
      'unrelated': 'preserve-me',
    });
    final store = ClientStateStore.withStorage(storage);

    final state = await store.load();

    expect(state.clientKey, hasLength(32));
    expect(state.hosts, isEmpty);
    expect(storage.values['zuko-client-state-v1'], isNull);
    expect(storage.values['zuko-client-state-v3'], isNull);
    expect(storage.values['zuko-client-state-v4'], isNull);
    expect(storage.values['zuko-client-state-v5'], isNull);
    expect(
      ClientState.decode(storage.values['zuko-client-state-v6']!),
      isA<ClientState>(),
    );
    expect(storage.values['unrelated'], 'preserve-me');
    expect(store.recoveredInvalidState, isTrue);
  });

  test('locked keyring fails closed without changing state', () async {
    final storage = _ThrowingStorage(
      PlatformException(code: 'KeyringLocked', message: 'KeyringLocked'),
    );
    final store = ClientStateStore.withStorage(storage);

    await expectLater(store.load(), throwsA(isA<KeyringLockedException>()));

    expect(storage.operations, ['read']);
    expect(store.recoveredInvalidState, isFalse);
  });

  test('locked keyring writes surface the recoverable error', () async {
    final storage = _ThrowingStorage(
      PlatformException(code: 'KeyringLocked', message: 'KeyringLocked'),
    );
    final store = ClientStateStore.withStorage(storage);
    final state = ClientState(clientKey: key, hosts: const []);

    await expectLater(
      store.save(state),
      throwsA(isA<KeyringLockedException>()),
    );

    expect(storage.operations, ['write']);
  });

  test('other platform storage errors are preserved', () async {
    final storage = _ThrowingStorage(
      PlatformException(code: 'StorageError', message: 'unavailable'),
    );
    final store = ClientStateStore.withStorage(storage);

    await expectLater(
      store.load(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'StorageError',
        ),
      ),
    );
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

final class _ThrowingStorage implements SecureStateStorage {
  _ThrowingStorage(this.error);

  final Object error;
  final List<String> operations = [];

  @override
  Future<void> delete(String key) async {
    operations.add('delete');
    throw error;
  }

  @override
  Future<String?> read(String key) async {
    operations.add('read');
    throw error;
  }

  @override
  Future<void> write(String key, String value) async {
    operations.add('write');
    throw error;
  }
}
