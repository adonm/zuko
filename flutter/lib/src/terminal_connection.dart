import 'dart:async';
import 'dart:convert';

import 'package:flterm/flterm.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show FocusNode, ValueNotifier;

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

String? decodeRemoteClipboardWrite(ClipboardWrite request) {
  if (request.location != ClipboardLocation.standard) return null;
  final contents = request.contents;
  if (contents.isEmpty) return null;
  final data = contents.first.data;
  if (data.length > maxRemoteClipboardBytes) return null;
  try {
    return utf8.decode(data, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

Future<void> _writeSystemClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

bool _inactiveClipboardSource() => false;

final class TerminalConnection {
  TerminalConnection({
    required SavedHost host,
    required this.connector,
    required this.onTunnel,
    bool Function()? isClipboardSourceActive,
    RemoteClipboardWriter? clipboardWriter,
  }) : host = ValueNotifier(host),
       _isClipboardSourceActive =
           isClipboardSourceActive ?? _inactiveClipboardSource,
       _clipboardWriter = clipboardWriter ?? _writeSystemClipboard,
       terminal = TerminalController() {
    terminal.onOutput = (bytes) {
      final session = _session;
      if (_acceptingIo && session != null) unawaited(session.send(bytes));
    };
    terminal.onClipboardWrite = _handleClipboardWrite;
    terminal.onResize = applyTerminalGeometry;
    terminal.write(
      Uint8List.fromList(
        '\x1b[1;38;2;197;64;74mzuko\x1b[0m ready\r\n'.codeUnits,
      ),
    );
  }

  final ValueNotifier<SavedHost> host;
  final TerminalConnector connector;
  final TerminalTunnelHandler onTunnel;
  final bool Function() _isClipboardSourceActive;
  final RemoteClipboardWriter _clipboardWriter;
  final TerminalController terminal;
  final FocusNode focusNode = FocusNode();
  final TerminalScrollController scrollController = TerminalScrollController();

  TerminalSession? _session;
  StreamSubscription<Uint8List>? _outputSubscription;
  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<TunnelEndpoint>? _tunnelSubscription;
  int _generation = 0;
  bool _acceptingIo = false;
  bool _closed = false;
  Timer? _resizeTimer;
  bool _resizeDirty = false;

  static const _resizeSettle = Duration(milliseconds: 200);

  final ValueNotifier<SessionState> state = ValueNotifier(
    const SessionState.connecting(),
  );
  TerminalGeometry geometry = const TerminalGeometry(80, 24, 0, 0);

  bool isCurrentGeneration(int generation) =>
      !_closed && generation == _generation;

  ClipboardWriteResult _handleClipboardWrite(ClipboardWrite request) {
    if (_closed || !_isClipboardSourceActive()) return .denied;
    final text = decodeRemoteClipboardWrite(request);
    if (text == null) return .denied;
    unawaited(_writeClipboard(text));
    return .success;
  }

  Future<void> _writeClipboard(String text) async {
    try {
      await _clipboardWriter(text);
    } on Object {
      // Clipboard denial must not interrupt terminal output processing.
    }
  }

  void applyTerminalGeometry(int cols, int rows) {
    geometry = TerminalGeometry(cols, rows, 0, 0);
    // Keyboard animation, rotation, and drawer motion fire bursts of resizes.
    // Send the first immediately so rotations stay snappy, then coalesce the
    // burst and send the final size once it settles — the PTY never draws
    // (and glitches on) transient sizes, and full-screen apps repaint once.
    final session = _session;
    if (_resizeTimer == null) {
      if (session != null) unawaited(session.resize(geometry));
    } else {
      _resizeDirty = true;
    }
    _resizeTimer?.cancel();
    _resizeTimer = Timer(_resizeSettle, () {
      _resizeTimer = null;
      if (!_resizeDirty) return;
      _resizeDirty = false;
      final pending = _session;
      if (pending != null) unawaited(pending.resize(geometry));
    });
  }

  Future<void> updateHost(SavedHost host) async {
    if (_closed) return;
    if (host.nodeId != this.host.value.nodeId) {
      throw ArgumentError.value(host.nodeId, 'host.nodeId', 'must not change');
    }
    final current = this.host.value;
    final ticketChanged = host.ticket != current.ticket;
    this.host.value = host;
    if (ticketChanged) {
      await reconnect();
    }
  }

  Future<void> reconnect() async {
    if (_closed) return;
    final generation = ++_generation;
    final previous = _detachSession();
    state.value = const SessionState.connecting();
    await previous.close();
    if (!isCurrentGeneration(generation)) return;

    try {
      final active = connector(host.value, geometry);
      if (!isCurrentGeneration(generation)) {
        await active.close();
        return;
      }
      _session = active;
      _outputSubscription = active.output.listen((bytes) {
        if (_acceptingIo &&
            isCurrentGeneration(generation) &&
            identical(_session, active)) {
          terminal.write(bytes);
        }
      });
      _stateSubscription = active.states.listen((next) {
        if (!isCurrentGeneration(generation) || !identical(_session, active)) {
          return;
        }
        _acceptingIo = next.isAttached;
        state.value = next;
      });
      _tunnelSubscription = active.tunnels.listen((tunnel) {
        if (isCurrentGeneration(generation) && identical(_session, active)) {
          onTunnel(this, tunnel, generation);
        }
      });
    } on Object {
      if (!isCurrentGeneration(generation)) return;
      state.value = const SessionState.failed(
        'Could not start this session. Check the host and try again.',
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    final previous = _detachSession();
    state.value = const SessionState.ended('Connection closed.');
    await previous.close();
  }

  _DetachedSession _detachSession() {
    _acceptingIo = false;
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

  /// Drops any coalesced resize without sending it. Called synchronously on
  /// teardown so no debounce timer outlives the connection.
  void cancelPendingResize() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    _resizeDirty = false;
  }

  void dispose() {
    _closed = true;
    _generation++;
    _resizeTimer?.cancel();
    _resizeTimer = null;
    focusNode.dispose();
    scrollController.dispose();
    terminal.dispose();
    host.dispose();
    state.dispose();
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
