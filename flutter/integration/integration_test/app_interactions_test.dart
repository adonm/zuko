import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalView;

import 'package:flutter/material.dart' show FilledButton, OutlinedButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_overlay.dart';
import 'package:zuko/src/storage.dart';

import 'local_host_transport.dart';

final class _MemoryStorage implements SecureStateStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<AppController> _controller(LocalHostTransport transport) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
    clientName: 'integration',
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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  int tries = 40,
}) async {
  for (var i = 0; i < tries && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Pairs a host through the welcome and pairing screens, then waits for the
/// connection to attach so the terminal is interactive.
Future<void> _pairThroughUi(
  WidgetTester tester,
  AppController controller,
) async {
  await tester.tap(find.text('Enter pairing code'));
  await _settle(tester);
  final shareCode = find.bySemanticsLabel(RegExp('Share code'));
  expect(shareCode, findsOneWidget);
  await tester.enterText(shareCode, 'local-device');
  await _settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
  // The claim resolves and the app opens the terminal automatically.
  await _waitFor(tester, () => controller.hosts.isNotEmpty);
  expect(controller.hosts, hasLength(1));
  await _waitFor(tester, () => find.byType(TerminalView).evaluate().isNotEmpty);
  expect(find.byType(TerminalView), findsOneWidget);
  // Wait until the attaching overlay clears so the terminal accepts input.
  await _waitFor(tester, () => find.byType(SessionOverlay).evaluate().isEmpty);
  expect(find.byType(SessionOverlay), findsNothing);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full UI journey against a real local shell', (tester) async {
    final transport = LocalHostTransport();
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();

    await _pairThroughUi(tester, controller);

    // The terminal surface is visible with the accessory key row.
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);

    // A real bash PTY is attached: wait for the prompt to arrive.
    await _waitFor(tester, () => transport.receivedBytes.isNotEmpty);
    expect(transport.receivedBytes, isNotEmpty);

    // --- Ctrl latch through the accessory drives the real key path. ---
    // Latch Ctrl, focus the terminal, then a hardware 'c' must merge into
    // Ctrl+C (0x03) on the wire.
    await tester.tap(find.text('Ctrl'));
    await _settle(tester);
    await tester.tap(find.byType(TerminalView));
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await _settle(tester);
    expect(transport.sentBytes, contains(0x03));

    // --- Accessory arrow keys send real escape sequences. ---
    await tester.tap(find.byTooltip('Up').first);
    await _settle(tester);
    expect(
      transport.sentBytes
          .where((byte) => byte == 0x1b || byte == 0x5b || byte == 0x41)
          .length,
      greaterThanOrEqualTo(3),
    );

    // --- Sidebar settings toggles update controller state and UI. ---
    await tester.tap(find.text('Touch text selection'));
    await _settle(tester);
    expect(controller.touchSelectionEnabled, isTrue);

    await tester.tap(find.text('Open keyboard on tap'));
    await _settle(tester);
    expect(controller.keyboardOnTap, isTrue);

    // --- Disconnect from the sidebar closes the session and kills the PTY. ---
    // The button sits at the bottom of the sidebar list; drag the list up.
    await tester.drag(find.text('Appearance'), const Offset(0, -220));
    await _settle(tester);
    await _waitFor(tester, () => find.text('Disconnect').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(transport.hasLiveSessions, isFalse);
  });

  testWidgets('btop renders a real TUI through flterm', (tester) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'btop'],
    );
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();

    await _pairThroughUi(tester, controller);

    // Give btop time to draw frames; flterm must receive ANSI escape
    // sequences and TUI content from the PTY.
    await _waitFor(
      tester,
      () => transport.receivedBytes.contains(0x1b),
      tries: 40,
    );
    expect(transport.receivedBytes.contains(0x1b), isTrue);
    expect(transport.receivedBytes.length, greaterThan(100));

    // The terminal widget is alive and connected to a controller.
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminal.controller, isNotNull);
  });
}
