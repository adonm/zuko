import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'model.dart';

final class ClientStateStore {
  ClientStateStore({FlutterSecureStorage? storage})
    : _storage = _FlutterSecureStateStorage(
        storage ?? const FlutterSecureStorage(),
      );

  @visibleForTesting
  ClientStateStore.withStorage(SecureStateStorage storage) : _storage = storage;

  static const _stateKey = 'zuko-client-state-v3';
  static const _legacyStateKey = 'zuko-client-state-v1';
  static const _iosOptions = IOSOptions(
    accountName: 'dev.adonm.zuko',
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _macosOptions = MacOsOptions(
    accountName: 'dev.adonm.zuko',
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  final SecureStateStorage _storage;
  bool recoveredInvalidState = false;

  Future<ClientState> load() async {
    final current = await _storage.read(_stateKey);
    if (current != null) return _decodeOrReset(current);

    final legacy = await _storage.read(_legacyStateKey);
    if (legacy != null) {
      final state = await _decodeOrReset(legacy);
      if (recoveredInvalidState) return state;
      await save(state);
      await _storage.delete(_legacyStateKey);
      return state;
    }
    return _createState();
  }

  Future<ClientState> _decodeOrReset(String encoded) async {
    try {
      return ClientState.decode(encoded);
    } on FormatException {
      recoveredInvalidState = true;
      await _storage.delete(_stateKey);
      await _storage.delete(_legacyStateKey);
      return _createState();
    }
  }

  Future<ClientState> _createState() async {
    final random = Random.secure();
    final state = ClientState(
      clientKey: Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      ),
      hosts: const [],
    );
    await save(state);
    return state;
  }

  Future<void> save(ClientState state) =>
      _storage.write(_stateKey, state.encode());
}

@visibleForTesting
abstract interface class SecureStateStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class _FlutterSecureStateStorage implements SecureStateStorage {
  const _FlutterSecureStateStorage(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(
    key: key,
    iOptions: ClientStateStore._iosOptions,
    mOptions: ClientStateStore._macosOptions,
  );

  @override
  Future<void> write(String key, String value) => _storage.write(
    key: key,
    value: value,
    iOptions: ClientStateStore._iosOptions,
    mOptions: ClientStateStore._macosOptions,
  );

  @override
  Future<void> delete(String key) => _storage.delete(
    key: key,
    iOptions: ClientStateStore._iosOptions,
    mOptions: ClientStateStore._macosOptions,
  );
}
