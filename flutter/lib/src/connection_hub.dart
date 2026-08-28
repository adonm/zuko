import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'terminal_connection.dart';

/// Owns the open terminal connections and the active selection.
///
/// The hub is the single source of truth for connection lifecycle:
/// opening, selecting, closing, and the background-to-foreground lease
/// refresh. Widgets subscribe for structural changes (membership and active
/// index) while per-connection details flow through the connection's own
/// value notifiers.
final class ConnectionHub extends ChangeNotifier {
  ConnectionHub({
    required this.connector,
    required this.onTunnel,
    required this.isClipboardSourceActive,
  });

  final TerminalConnector connector;
  final TerminalTunnelHandler onTunnel;
  final bool Function(TerminalConnection connection) isClipboardSourceActive;

  final List<TerminalConnection> connections = [];
  int activeIndex = -1;
  DateTime? _backgroundedAt;

  TerminalConnection? get active {
    if (activeIndex < 0 || activeIndex >= connections.length) return null;
    return connections[activeIndex];
  }

  TerminalConnection? forHost(SavedHost host) {
    for (final connection in connections) {
      if (connection.host.value.nodeId == host.nodeId) return connection;
    }
    return null;
  }

  /// Opens a connection for [host], selecting it. Existing connections for
  /// the same host are selected instead of duplicated.
  TerminalConnection open(SavedHost host) {
    final existing = forHost(host);
    if (existing != null) {
      select(existing);
      return existing;
    }
    late final TerminalConnection connection;
    connection = TerminalConnection(
      host: host,
      connector: connector,
      onTunnel: onTunnel,
      isClipboardSourceActive: () => isClipboardSourceActive(connection),
    );
    connections.add(connection);
    activeIndex = connections.length - 1;
    notifyListeners();
    unawaited(connection.reconnect());
    return connection;
  }

  void select(TerminalConnection connection) {
    final index = connections.indexOf(connection);
    if (index < 0 || index == activeIndex) return;
    activeIndex = index;
    notifyListeners();
  }

  /// Closes and disposes [connection], keeping the active index valid.
  Future<void> close(TerminalConnection connection) async {
    final index = connections.indexOf(connection);
    if (index < 0) return;
    connections.removeAt(index);
    if (activeIndex >= connections.length) {
      activeIndex = connections.length - 1;
    } else if (index < activeIndex) {
      activeIndex -= 1;
    }
    notifyListeners();
    await connection.close();
    connection.dispose();
  }

  /// Refreshes sessions that were backgrounded long enough for the relay to
  /// drop their detached lease.
  void handleLifecycleResumed() {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >=
            const Duration(seconds: 5)) {
      for (final connection in List.of(connections)) {
        unawaited(connection.reconnect());
      }
    }
  }

  void handleLifecyclePaused() {
    _backgroundedAt ??= DateTime.now();
  }

  /// Closes and disposes every connection. The hub is unusable afterwards.
  Future<void> disposeAll() async {
    final snapshot = List.of(connections);
    connections.clear();
    activeIndex = -1;
    notifyListeners();
    for (final connection in snapshot) {
      await connection.close();
      connection.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(disposeAll());
    super.dispose();
  }
}
