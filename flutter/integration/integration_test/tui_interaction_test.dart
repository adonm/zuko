import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalView;
import 'package:flutter/material.dart' show FilledButton;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/storage.dart';

import 'local_host_transport.dart';

/// Touch interaction coverage against a real mouse-capable TUI: yazi enables
/// mouse tracking, so clicks must reach it as SGR mouse reports, and a
/// long-press drag over the terminal must arm flterm's local selection.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openPairedApp(
    WidgetTester tester,
    AppController controller,
  ) async {
    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.bySemanticsLabel(RegExp('Share code')),
      'alpha-bravo',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
  }

  testWidgets('yazi receives clicks and long-press arms selection', (
    tester,
  ) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'yazi'],
    );
    final controller = await _controller(transport);
    addTearDown(controller.close);
    await openPairedApp(tester, controller);

    // Let yazi draw and enable mouse tracking.
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (transport.receivedBytes.contains(0x1b)) break;
    }
    await tester.pump(const Duration(milliseconds: 400));

    // A click on the terminal must produce an SGR mouse report at the PTY.
    final terminalRect = tester.getRect(find.byType(TerminalView));
    final before = transport.sentBytes.length;
    await tester.tapAt(
      Offset(
        terminalRect.left + terminalRect.width * 0.5,
        terminalRect.top + terminalRect.height * 0.5,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final clickBytes = transport.sentBytes.sublist(before);
    expect(clickBytes, contains(0x1b));
    expect(clickBytes, contains(0x3c)); // SGR mouse

    // A long-press drag on the terminal arms the local text selection: the
    // accessory paste slot switches to the copy tooltip.
    final start = Offset(
      terminalRect.left + terminalRect.width * 0.3,
      terminalRect.top + terminalRect.height * 0.5,
    );
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(Offset(terminalRect.width * 0.2, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Copy selected text'), findsOneWidget);
  });

  testWidgets('yazi picks the Kitty graphics adapter', (tester) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'ya env'],
    );
    final controller = await _controller(transport);
    addTearDown(controller.close);
    await openPairedApp(tester, controller);

    // ya env probes the terminal the same way yazi does before picking an
    // image adapter. Under the resolved session TERM it must probe the
    // Kitty graphics protocol (ESC _ G); under xterm-256color it would
    // take the Sixel path and emit none of these probes. The client renders
    // Kitty graphics, so this is the adapter-detection proof — ya env may
    // then stall awaiting query responses, which is fine for the assertion.
    if (transport.sessionTerm != 'xterm-kitty') {
      markTestSkipped(
        'xterm-kitty terminfo not installed; host sessions would fall '
        'back to xterm-256color (see zuko doctor)',
      );
      return;
    }
    var sawKittyProbe = false;
    for (var attempt = 0; attempt < 40 && !sawKittyProbe; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      final bytes = transport.receivedBytes;
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0x1b && bytes[i + 1] == 0x5f && bytes[i + 2] == 0x47) {
          sawKittyProbe = true;
          break;
        }
      }
    }
    expect(sawKittyProbe, isTrue);
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

Future<AppController> _controller(LocalHostTransport transport) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
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
