import 'dart:async';
import 'dart:convert';

import 'package:flterm/flterm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:libghostty/libghostty.dart' show ClipboardWrite;

import 'model.dart';
import 'session_state.dart';
import 'transport.dart';
import 'wire.dart';

typedef TerminalConnector =
    TerminalSession Function(SavedHost host, TerminalGeometry geometry);
typedef TerminalTunnelHandler =
    void Function(
      TerminalConnection connection,
      TunnelEndpoint tunnel,
      int generation,
    );
typedef RemoteClipboardWriter = Future<void> Function(String text);

const maxRemoteClipboardBytes = 1024 * 1024;
const _maxRemoteClipboardBase64Bytes = ((maxRemoteClipboardBytes + 2) ~/ 3) * 4;
final _strictBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

String? decodeRemoteClipboardWrite(ClipboardWrite request) {
  if (request.selector != 'c'.codeUnitAt(0) ||
      request.payload.length > _maxRemoteClipboardBase64Bytes) {
    return null;
  }
  try {
    final encoded = ascii.decode(request.payload, allowInvalid: false);
    final match = _strictBase64.firstMatch(encoded);
    if (match == null || match.end != encoded.length) return null;
    final decoded = base64.decode(encoded);
    if (decoded.length > maxRemoteClipboardBytes) return null;
    return utf8.decode(decoded, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

Future<void> _writeSystemClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

bool _inactiveClipboardSource() => false;

final class TerminalConnection extends ChangeNotifier {
  TerminalConnection({
    required this.host,
    required this.connector,
    required this.onTunnel,
    bool Function()? isClipboardSourceActive,
    RemoteClipboardWriter? clipboardWriter,
  }) : _isClipboardSourceActive =
           isClipboardSourceActive ?? _inactiveClipboardSource,
       _clipboardWriter = clipboardWriter ?? _writeSystemClipboard,
       terminal = TerminalController() {
    terminal.onOutput = (bytes) => unawaited(_session?.send(bytes));
    terminal.onClipboardWrite = _handleClipboardWrite;
    terminal.onResize = (cols, rows) {
      geometry = TerminalGeometry(cols, rows, 0, 0);
      unawaited(_session?.resize(geometry));
    };
    terminal.write(
      Uint8List.fromList(
        '\x1b[1;38;2;197;64;74mzuko\x1b[0m ready\r\n'.codeUnits,
      ),
    );
  }

  SavedHost host;
  final TerminalConnector connector;
  final TerminalTunnelHandler onTunnel;
  final bool Function() _isClipboardSourceActive;
  final RemoteClipboardWriter _clipboardWriter;
  final TerminalController terminal;

  TerminalSession? _session;
  StreamSubscription<Uint8List>? _outputSubscription;
  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<TunnelEndpoint>? _tunnelSubscription;
  int _generation = 0;
  bool _closed = false;
  bool _disposed = false;

  SessionState state = const SessionState.connecting();
  TerminalGeometry geometry = const TerminalGeometry(80, 24, 0, 0);
  bool touchSelectionEnabled = false;

  bool isCurrentGeneration(int generation) =>
      !_closed && generation == _generation;

  void _handleClipboardWrite(ClipboardWrite request) {
    if (_closed || !_isClipboardSourceActive()) return;
    final text = decodeRemoteClipboardWrite(request);
    if (text == null) return;
    unawaited(_writeClipboard(text));
  }

  Future<void> _writeClipboard(String text) async {
    try {
      await _clipboardWriter(text);
    } on Object {
      // Clipboard denial must not interrupt terminal output processing.
    }
  }

  void setTouchSelectionEnabled(bool enabled) {
    if (touchSelectionEnabled == enabled) return;
    touchSelectionEnabled = enabled;
    if (!enabled) terminal.clearSelection();
    _notify();
  }

  Future<void> updateHost(SavedHost host) async {
    if (_closed) return;
    if (host.nodeId != this.host.nodeId) {
      throw ArgumentError.value(host.nodeId, 'host.nodeId', 'must not change');
    }
    final ticketChanged = host.ticket != this.host.ticket;
    this.host = host;
    if (ticketChanged) {
      await reconnect();
    } else {
      _notify();
    }
  }

  Future<void> reconnect() async {
    if (_closed) return;
    final generation = ++_generation;
    final previous = _detachSession();
    state = const SessionState.connecting();
    _notify();
    await previous.close();
    if (!isCurrentGeneration(generation)) return;

    try {
      final active = connector(host, geometry);
      if (!isCurrentGeneration(generation)) {
        await active.close();
        return;
      }
      _session = active;
      _outputSubscription = active.output.listen((bytes) {
        if (isCurrentGeneration(generation) && identical(_session, active)) {
          terminal.write(bytes);
        }
      });
      _stateSubscription = active.states.listen((next) {
        if (!isCurrentGeneration(generation) || !identical(_session, active)) {
          return;
        }
        state = next;
        _notify();
      });
      _tunnelSubscription = active.tunnels.listen((tunnel) {
        if (isCurrentGeneration(generation) && identical(_session, active)) {
          onTunnel(this, tunnel, generation);
        }
      });
      _notify();
    } on Object {
      if (!isCurrentGeneration(generation)) return;
      state = const SessionState.failed(
        'Could not start this session. Check the host and try again.',
      );
      _notify();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    final previous = _detachSession();
    state = const SessionState.ended('Connection closed.');
    _notify();
    await previous.close();
  }

  _DetachedSession _detachSession() {
    final detached = _DetachedSession(
      session: _session,
      output: _outputSubscription,
      states: _stateSubscription,
      tunnels: _tunnelSubscription,
    );
    _session = null;
    _outputSubscription = null;
    _stateSubscription = null;
    _tunnelSubscription = null;
    return detached;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _disposed = true;
    _generation++;
    terminal.dispose();
    super.dispose();
  }
}

final class _DetachedSession {
  const _DetachedSession({
    required this.session,
    required this.output,
    required this.states,
    required this.tunnels,
  });

  final TerminalSession? session;
  final StreamSubscription<Uint8List>? output;
  final StreamSubscription<SessionState>? states;
  final StreamSubscription<TunnelEndpoint>? tunnels;

  Future<void> close() async {
    for (final subscription in [output, states, tunnels]) {
      if (subscription == null) continue;
      try {
        await subscription.cancel();
      } on Object {
        // Continue closing the remaining tab-owned resources.
      }
    }
    try {
      await session?.close();
    } on Object {
      // Closing a tab is best-effort and must not strand the shared transport.
    }
  }
}
