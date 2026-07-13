import 'package:flutter/foundation.dart';

import 'client_name.dart';
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
  String status = 'Ready to connect';

  Uint8List get clientKey => Uint8List.fromList(_state.clientKey);
  List<SavedHost> get hosts => _state.hosts;
  AppThemePreference get theme => _state.theme;
  double get terminalFontSize => _state.terminalFontSize;
  bool get terminalFontSizeCustomized => _state.terminalFontSizeCustomized;
  bool get showAdditionalKeys => _state.showAdditionalKeys;
  String get clientName => _state.clientName ?? 'device';
  String get clientLabel => clientAuthorizationLabel(clientName, clientKey);

  static Future<AppController> create() async {
    final store = ClientStateStore();
    var state = await store.load();
    if (state.clientName == null) {
      state = state.copyWith(clientName: await suggestClientName());
      await store.save(state);
    }
    final transport = await createClientTransport(state.clientKey);
    final controller = AppController._(store, state, transport);
    if (store.recoveredInvalidState) {
      controller.status =
          'Local Zuko state was invalid and has been reset. Pair a host again.';
    }
    return controller;
  }

  Future<SavedHost> claim(String code) async {
    busy = true;
    status = 'Pairing with host…';
    notifyListeners();
    try {
      final normalizedCode = PairingCode.parse(code);
      if (normalizedCode == null) {
        throw const FormatException(
          'Enter the two-word code shown by zuko share.',
        );
      }
      final clientLabel = this.clientLabel;
      final result = await transport.claim(normalizedCode, clientLabel);
      final displayName = _displayName(result.label);
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
      status = 'Paired with ${result.label}';
      return host;
    } catch (error) {
      status = 'Pairing failed. Run zuko share again and retry.';
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

  Future<void> setClientName(String value) {
    final normalized = normalizeClientName(value);
    if (normalized.isEmpty) {
      return Future.error(
        const FormatException('Enter a device name with letters or numbers.'),
      );
    }
    return _commit((state) => state.copyWith(clientName: normalized));
  }

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
