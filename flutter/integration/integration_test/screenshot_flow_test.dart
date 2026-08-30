import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show ByteData, Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show FilledButton, RepaintBoundary;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/storage.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

/// Real-app pairing-flow screenshots captured by `flutter drive` (see
/// `just screenshots`). Unlike the widget-test generator, these render through
/// the real engine and the app's own fonts.
final _shotKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // Render through the real engine at 2x for crisp images.
  final image = (await tester.runAsync<ui.Image?>(
    () => boundary.toImage(pixelRatio: 2),
  ))!;
  final bytes = (await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  ))!;
  final directory = Directory('../../docs/images');
  directory.createSync(recursive: true);
  File(
    '${directory.path}/$name.png',
  ).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture the pairing flow screenshots', (tester) async {
    final transport = _FakeTransport();
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: ZukoApp(controller: controller),
      ),
    );
    await tester.pump();
    await _capture(tester, 'welcome');

    // Manual pairing screen (desktop has no camera).
    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    await _capture(tester, 'pairing-code');

    // Claim and capture the brief confirmation state.
    await tester.enterText(
      find.bySemanticsLabel(RegExp('Share code')),
      'alpha-bravo',
    );
    // Rebuild so the Pair button's validator sees the entered code.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump(const Duration(milliseconds: 120));
    await _capture(tester, 'pairing-confirmed');

    // The connection opens and stays in the connecting overlay because the
    // fake session never attaches.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await _capture(tester, 'connecting');

    final session = transport.sessions.single;
    session.emitState(
      const SessionState.retrying(
        'Connection lost. Retrying…',
        retryAfter: Duration(seconds: 4),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await _capture(tester, 'retrying');

    session.emitState(const SessionState.attached());
    session.emitOutput(
      '\r\n'
      '\x1b[1;32madonm@workstation\x1b[0m:\x1b[1;34m~\x1b[0m\$ zuko ls\r\n'
      '  workstation  office  \x1b[1;32mattached\x1b[0m\r\n',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, 'connected');
  });
}

final class _MemoryStorage implements SecureStateStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<AppController> _controller(_FakeTransport transport) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: 'zuko-test-client',
    hosts: const [],
  );
  final store = ClientStateStore.withStorage(_MemoryStorage());
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: transport,
  );
}

final class _FakeTransport implements ClientTransport {
  final List<_FakeSession> sessions = [];

  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    return const ClaimResult(
      label: 'workstation',
      ticket: 'ticket',
      nodeId: 'node',
    );
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
    final session = _FakeSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {}
}

final class _FakeSession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);

  void emitState(SessionState value) => _states.add(value);
  void emitOutput(String value) =>
      _output.add(Uint8List.fromList(value.codeUnits));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  @override
  Future<void> send(List<int> bytes) async {}

  @override
  Future<void> resize(TerminalGeometry geometry) async {}

  @override
  Future<void> close() async {
    await _output.close();
    await _states.close();
    await _tunnels.close();
  }
}
