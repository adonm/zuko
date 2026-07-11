import 'dart:typed_data';

import 'model.dart';
import 'session_state.dart';
import 'wire.dart';

final class ClaimResult {
  const ClaimResult({
    required this.label,
    required this.ticket,
    required this.nodeId,
  });
  final String label;
  final String ticket;
  final String nodeId;
}

final class TunnelEndpoint {
  const TunnelEndpoint({
    required this.id,
    required this.hostPort,
    required this.localPort,
  });

  final String id;
  final int hostPort;
  final int localPort;
  Uri get browserUrl =>
      Uri(scheme: 'http', host: '127.0.0.1', port: localPort, path: '/');
}

abstract interface class ClientTransport {
  Future<ClaimResult> claim(String code, String clientLabel);
  TerminalSession connect(SavedHost host, TerminalGeometry geometry);
  Future<void> close();
}

abstract interface class TerminalSession {
  Stream<Uint8List> get output;
  Stream<SessionState> get states;
  Stream<TunnelEndpoint> get tunnels;
  Future<void> send(List<int> bytes);
  Future<void> resize(TerminalGeometry geometry);
  Future<void> close();
}
