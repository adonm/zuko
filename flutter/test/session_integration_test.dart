import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/terminal_connection.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

const _host = SavedHost(
  name: 'Home',
  label: 'home',
  ticket: 'ticket',
  nodeId: 'node',
);

void main() {
  test('shared terminal boundary admits I/O only while attached', () async {
    final session = _HarnessSession();
    var connections = 0;
    final connection = TerminalConnection(
      host: _host,
      connector: (_, _) {
        connections++;
        return session;
      },
      onTunnel: (_, _, _) {},
    );
    addTearDown(() async {
      await connection.close();
      connection.dispose();
    });

    await connection.reconnect();
    session.emitOutput('early-output');
    connection.terminal.sendText('early-input');
    await Future<void>.delayed(Duration.zero);
    expect(_terminalText(connection), isNot(contains('early-output')));
    expect(session.sent, isEmpty);

    session.emitState(const SessionState.attached());
    session.emitOutput('accepted-output');
    connection.terminal.sendText('accepted-input');
    await Future<void>.delayed(Duration.zero);
    expect(_terminalText(connection), contains('accepted-output'));
    expect(utf8.decode(session.sent.single), 'accepted-input');

    session.emitState(const SessionState.retrying('link lost'));
    session.emitOutput('late-output');
    connection.terminal.sendText('late-input');
    await Future<void>.delayed(Duration.zero);
    expect(_terminalText(connection), isNot(contains('late-output')));
    expect(session.sent, hasLength(1));

    session.emitState(const SessionState.rejected('access revoked'));
    await Future<void>.delayed(Duration.zero);
    expect(connection.state.recovery, SessionRecovery.rePair);
    expect(connections, 1);
  });

  test('shared terminal boundary handles sustained ordered traffic', () async {
    final session = _HarnessSession();
    final connection = TerminalConnection(
      host: _host,
      connector: (_, _) => session,
      onTunnel: (_, _, _) {},
    );
    addTearDown(() async {
      await connection.close();
      connection.dispose();
    });
    await connection.reconnect();
    session.emitState(const SessionState.attached());

    for (var index = 0; index < 2000; index++) {
      session.emitOutput('line-$index\r\n');
      connection.terminal.sendText('input-$index\n');
    }
    await Future<void>.delayed(Duration.zero);

    expect(session.sent, hasLength(2000));
    expect(utf8.decode(session.sent.first), 'input-0\n');
    expect(utf8.decode(session.sent.last), 'input-1999\n');
    expect(_terminalText(connection), contains('line-1999'));
  });

  test(
    'malformed session failure cannot leak stale traffic after reconnect',
    () async {
      final sessions = <_HarnessSession>[];
      final connection = TerminalConnection(
        host: _host,
        connector: (_, _) {
          final session = _HarnessSession();
          sessions.add(session);
          return session;
        },
        onTunnel: (_, _, _) {},
      );
      addTearDown(() async {
        await connection.close();
        connection.dispose();
      });

      await connection.reconnect();
      sessions.single.emitState(
        const SessionState.failed('Protocol error: malformed frame.'),
      );
      sessions.single.emitOutput('rejected-output');
      await Future<void>.delayed(Duration.zero);
      expect(connection.state.message, contains('malformed frame'));
      expect(_terminalText(connection), isNot(contains('rejected-output')));

      final old = sessions.single;
      await connection.reconnect();
      sessions.last.emitState(const SessionState.attached());
      old.emitOutput('stale-output');
      sessions.last.emitOutput('current-output');
      await Future<void>.delayed(Duration.zero);

      expect(old.closed, isTrue);
      expect(_terminalText(connection), isNot(contains('stale-output')));
      expect(_terminalText(connection), contains('current-output'));
    },
  );
}

String _terminalText(TerminalConnection connection) => connection.terminal
    .createFormatter(format: FormatterFormat.plain, trim: true)
    .format();

final class _HarnessSession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  final List<Uint8List> sent = [];
  bool closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  void emitOutput(String value) =>
      _output.add(Uint8List.fromList(utf8.encode(value)));

  void emitState(SessionState value) => _states.add(value);

  @override
  Future<void> send(List<int> bytes) async {
    sent.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> resize(TerminalGeometry geometry) async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}
