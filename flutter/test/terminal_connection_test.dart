import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/terminal_connection.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

const _alpha = SavedHost(
  name: 'Alpha',
  label: 'alpha',
  ticket: 'ticket-alpha',
  nodeId: 'node-alpha',
);
const _beta = SavedHost(
  name: 'Beta',
  label: 'beta',
  ticket: 'ticket-beta',
  nodeId: 'node-beta',
);

void main() {
  test(
    'parallel terminal connections keep independent session state',
    () async {
      final sessions = <_FakeTerminalSession>[];
      TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
        final session = _FakeTerminalSession();
        sessions.add(session);
        return session;
      }

      final alpha = TerminalConnection(
        host: _alpha,
        connector: connect,
        onTunnel: (_, _, _) {},
      );
      final beta = TerminalConnection(
        host: _beta,
        connector: connect,
        onTunnel: (_, _, _) {},
      );
      addTearDown(() async {
        await alpha.close();
        await beta.close();
        alpha.dispose();
        beta.dispose();
      });

      await Future.wait([alpha.reconnect(), beta.reconnect()]);
      sessions[0].emitState(const SessionState.attached('Alpha attached'));
      sessions[1].emitState(const SessionState.retrying('Beta retrying'));

      expect(alpha.state.message, 'Alpha attached');
      expect(beta.state.message, 'Beta retrying');
      expect(sessions, hasLength(2));
    },
  );

  test(
    'reconnect closes the old session and ignores its late events',
    () async {
      final sessions = <_FakeTerminalSession>[];
      final connection = TerminalConnection(
        host: _alpha,
        connector: (_, _) {
          final session = _FakeTerminalSession();
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
      final old = sessions.single;
      await connection.reconnect();
      final current = sessions.last;
      current.emitState(const SessionState.attached());
      old.emitState(const SessionState.failed('stale failure'));

      expect(old.closed, isTrue);
      expect(connection.state.isAttached, isTrue);
    },
  );

  test('refreshed host ticket replaces the open session credentials', () async {
    final connectedHosts = <SavedHost>[];
    final sessions = <_FakeTerminalSession>[];
    final connection = TerminalConnection(
      host: _alpha,
      connector: (host, _) {
        connectedHosts.add(host);
        final session = _FakeTerminalSession();
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
    const refreshed = SavedHost(
      name: 'Alpha refreshed',
      label: 'alpha',
      ticket: 'ticket-alpha-refreshed',
      nodeId: 'node-alpha',
    );
    await connection.updateHost(refreshed);

    expect(connectedHosts, [_alpha, refreshed]);
    expect(sessions.first.closed, isTrue);
    expect(connection.host, same(refreshed));
  });

  test('terminal input and resize route to the owning session', () async {
    final session = _FakeTerminalSession();
    final connection = TerminalConnection(
      host: _alpha,
      connector: (_, _) => session,
      onTunnel: (_, _, _) {},
    );
    addTearDown(() async {
      await connection.close();
      connection.dispose();
    });
    await connection.reconnect();

    connection.terminal.sendText('hello');
    connection.terminal.onResize?.call(100, 40);
    await Future<void>.delayed(Duration.zero);

    expect(String.fromCharCodes(session.sent.single), 'hello');
    expect(session.resizes.single.cols, 100);
    expect(session.resizes.single.rows, 40);
  });

  testWidgets('Yaru connection tabs select and close independently', (
    tester,
  ) async {
    final alpha = TerminalConnection(
      host: _alpha,
      connector: (_, _) => _FakeTerminalSession(),
      onTunnel: (_, _, _) {},
    );
    final beta = TerminalConnection(
      host: _beta,
      connector: (_, _) => _FakeTerminalSession(),
      onTunnel: (_, _, _) {},
    );
    final controller = TabController(length: 2, vsync: const TestVSync());
    addTearDown(() {
      controller.dispose();
      alpha.dispose();
      beta.dispose();
    });
    final selected = <int>[];
    final closed = <TerminalConnection>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionTabStrip(
            controller: controller,
            selectedIndex: 0,
            connections: [alpha, beta],
            labelFor: (connection) => connection.host.name,
            onSelected: selected.add,
            onClose: closed.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(selected, [1]);

    selected.clear();
    await tester.tap(find.byTooltip('Close Alpha'));
    await tester.pump();
    expect(closed, [alpha]);
    expect(selected, isEmpty);
  });

  testWidgets('connection tabs scroll instead of overflowing', (tester) async {
    final connections = List.generate(
      6,
      (index) => TerminalConnection(
        host: SavedHost(
          name: 'Host $index',
          label: 'host-$index',
          ticket: 'ticket-$index',
          nodeId: 'node-$index',
        ),
        connector: (_, _) => _FakeTerminalSession(),
        onTunnel: (_, _, _) {},
      ),
    );
    final controller = TabController(length: 6, vsync: const TestVSync());
    addTearDown(() {
      controller.dispose();
      for (final connection in connections) {
        connection.dispose();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: ConnectionTabStrip(
                controller: controller,
                selectedIndex: 0,
                connections: connections,
                labelFor: (connection) => connection.host.name,
                onSelected: (_) {},
                onClose: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scrollView.controller!.position.maxScrollExtent, greaterThan(0));

    controller.index = 5;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: ConnectionTabStrip(
                controller: controller,
                selectedIndex: 5,
                connections: connections,
                labelFor: (connection) => connection.host.name,
                onSelected: (_) {},
                onClose: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(scrollView.controller!.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

final class _FakeTerminalSession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  final List<List<int>> sent = [];
  final List<TerminalGeometry> resizes = [];
  bool closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  void emitState(SessionState state) => _states.add(state);

  @override
  Future<void> send(List<int> bytes) async {
    sent.add(List.of(bytes));
  }

  @override
  Future<void> resize(TerminalGeometry geometry) async {
    resizes.add(geometry);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
