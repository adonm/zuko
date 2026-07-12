import 'package:flutter/foundation.dart';

import 'model.dart';
import 'pairing_code.dart';
import 'storage.dart';
import 'transport.dart';
import 'transport_factory.dart';

final class AppController extends ChangeNotifier {
  AppController._(this._store, this._state, this.transport);

  final ClientStateStore _store;
  ClientState _state;
  final ClientTransport transport;
  Future<void> _saveTail = Future.value();
  bool busy = false;
  String status = 'ready';

  Uint8List get clientKey => Uint8List.fromList(_state.clientKey);
  List<SavedHost> get hosts => _state.hosts;
  AppThemePreference get theme => _state.theme;
  double get terminalFontSize => _state.terminalFontSize;
  bool get terminalFontSizeCustomized => _state.terminalFontSizeCustomized;
  bool get showAdditionalKeys => _state.showAdditionalKeys;

  static Future<AppController> create() async {
    final store = ClientStateStore();
    final state = await store.load();
    final transport = await createClientTransport(state.clientKey);
    final controller = AppController._(store, state, transport);
    if (store.recoveredInvalidState) {
      controller.status =
          'Local Zuko state was invalid and has been reset. Pair a host again.';
    }
    return controller;
  }

  Future<SavedHost> claim(String code, String name) async {
    busy = true;
    status = 'claiming host...';
    notifyListeners();
    try {
      final normalizedCode = PairingCode.parse(code);
      if (normalizedCode == null) {
        throw const FormatException(
          'Enter the two-word code shown by zuko share.',
        );
      }
      final fingerprint = _state.clientKey
          .take(3)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
      final clientLabel = 'zuko-$platform-$fingerprint';
      final result = await transport.claim(normalizedCode, clientLabel);
      final displayName = _displayName(name.isEmpty ? result.label : name);
      final host = SavedHost(
        name: displayName,
        label: result.label,
        ticket: result.ticket,
        nodeId: result.nodeId,
        authorizedClientLabel: clientLabel,
      );
      await _commit(
        (state) => state.copyWith(
          hosts: [
            host,
            ...state.hosts.where((item) => item.nodeId != host.nodeId),
          ].take(12).toList(),
        ),
      );
      status = 'paired with ${result.label}';
      return host;
    } catch (error) {
      status = 'pairing failed: $error';
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> remove(SavedHost host) async {
    await _commit(
      (state) => state.copyWith(
        hosts: state.hosts.where((item) => item.nodeId != host.nodeId).toList(),
      ),
    );
  }

  Future<void> rename(SavedHost host, String name) => _commit(
    (state) => state.copyWith(
      hosts: state.hosts
          .map(
            (item) => item.nodeId == host.nodeId
                ? item.copyWith(name: _displayName(name))
                : item,
          )
          .toList(),
    ),
  );

  Future<void> setTheme(AppThemePreference value) =>
      _commit((state) => state.copyWith(theme: value));

  Future<void> setTerminalFontSize(double value) => _commit(
    (state) => state.copyWith(
      terminalFontSize: value,
      terminalFontSizeCustomized: true,
    ),
  );

  Future<void> setShowAdditionalKeys(bool value) =>
      _commit((state) => state.copyWith(showAdditionalKeys: value));

  void setStatus(String value) {
    status = value;
    notifyListeners();
  }

  Future<void> _commit(ClientState Function(ClientState state) update) {
    final operation = _saveTail.then((_) async {
      final next = update(_state);
      await _store.save(next);
      _state = next;
      notifyListeners();
    });
    _saveTail = operation.catchError((_) {});
    return operation;
  }

  Future<void> close() async {
    await _saveTail;
    await transport.close();
  }
}

String _displayName(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return 'host';
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
}
