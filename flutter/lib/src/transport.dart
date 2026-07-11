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

abstract interface class ClientTransport {
  Future<ClaimResult> claim(String code, String clientLabel);
  TerminalSession connect(SavedHost host, TerminalGeometry geometry);
  Future<void> close();
}

abstract interface class TerminalSession {
  Stream<Uint8List> get output;
  Stream<SessionState> get states;
  Future<void> send(List<int> bytes);
  Future<void> resize(TerminalGeometry geometry);
  Future<void> close();
}
