import 'dart:async';
import 'dart:io' show Process;
import 'dart:typed_data';

import 'package:ptyx/ptyx.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

/// Mirrors the host's session TERM resolution: `zuko host` advertises
/// `xterm-kitty` when the terminfo entry exists so TUIs like yazi pick the
/// Kitty graphics adapter the client renders, and falls back to
/// `xterm-256color` otherwise. Integration tests probe the same way so the
/// TUI suite exercises whichever TERM a real host would choose.
String probeSessionTerm() {
  final result = Process.runSync('infocmp', const ['xterm-kitty']);
  return result.exitCode == 0 ? 'xterm-kitty' : 'xterm-256color';
}

/// Bridges the Flutter app to real local pseudo-terminal sessions.
///
/// Every `connect` spawns the configured shell in a PTY and forwards terminal
/// output bytes into the session stream while writing app-sent bytes to the
/// PTY. This lets integration tests drive the real UI against real terminal
/// programs (bash, btop, vim) with no network involved.
final class LocalHostTransport implements ClientTransport {
  LocalHostTransport({this.command = const ['/usr/bin/bash', '--norc', '-i']})
    : sessionTerm = probeSessionTerm();

  final List<String> command;

  /// The TERM sessions under this transport advertise (host-equivalent).
  final String sessionTerm;
  final List<_LocalSession> _sessions = [];

  /// Bytes written into the PTY by every live session, for assertions.
  final List<int> sentBytes = [];

  /// Bytes emitted by the PTY to the app, for assertions.
  final List<int> receivedBytes = [];

  /// Claims any code, returning a fixed local host.
  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    return const ClaimResult(
      label: 'local',
      ticket: 'ticket-local',
      nodeId: 'node-local',
    );
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
    final session = _LocalSession(
      command: command,
      onSent: sentBytes.addAll,
      onReceived: receivedBytes.addAll,
      term: sessionTerm,
    );
    _sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    for (final session in List.of(_sessions)) {
      await session.close();
    }
    _sessions.clear();
  }

  bool get hasLiveSessions => _sessions.any((session) => !session.closed);
}

final class _LocalSession implements TerminalSession {
  _LocalSession({
    required this.command,
    required this.onSent,
    required this.onReceived,
    required this.term,
  });

  final List<String> command;
  final void Function(List<int>) onSent;
  final void Function(List<int>) onReceived;
  final String term;
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  PtySession? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  bool closed = false;

  @override
  Stream<Uint8List> get output {
    final controller = StreamController<Uint8List>();
    final pty = PtySession.spawn(
      PtySpawnOptions(
        executable: command.first,
        arguments: command.skip(1).toList(),
        environment: {'TERM': term},
        initialSize: const PtySize(rows: 30, columns: 100),
      ),
    );
    _pty = pty;
    _outputSub = pty.output.listen(
      (chunk) {
        onReceived(chunk);
        controller.add(chunk);
      },
      onDone: controller.close,
      onError: controller.addError,
    );
    // The real transport reports attachment once the host confirms the
    // session; the local PTY is attached as soon as it spawns.
    scheduleMicrotask(() {
      if (!closed) _states.add(const SessionState.attached());
    });
    return controller.stream;
  }

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  @override
  Future<void> send(List<int> bytes) async {
    onSent(bytes);
    _pty?.write(Uint8List.fromList(bytes));
  }

  @override
  Future<void> resize(TerminalGeometry geometry) async {
    if (geometry.cols > 0 && geometry.rows > 0) {
      _pty?.resize(PtySize(rows: geometry.rows, columns: geometry.cols));
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _outputSub?.cancel();
    await _pty?.close();
    await _states.close();
    await _tunnels.close();
  }
}
