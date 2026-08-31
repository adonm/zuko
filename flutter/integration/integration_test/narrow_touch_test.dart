import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalView;
import 'package:flutter/material.dart' show AppBar, FilledButton;
import 'package:flutter/widgets.dart' show Element, FocusManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/floating_terminal_pad.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/storage.dart';

import 'local_host_transport.dart';

/// Narrow touch-shell coverage on the real app: the runner sizes the window
/// from ZUKO_WINDOW_SIZE (390x844 here) and ZUKO_FORCE_TOUCH_PAD opts into
/// the touch layout, so the drawer flow, corner logo, and pad can be driven
/// on CI at phone dimensions.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('narrow touch layout: drawer flow and pad keys', (tester) async {
    final transport = LocalHostTransport();
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();

    // Touch shell: no app bar, and the floating corner logo opens the
    // drawer on narrow layouts.
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Open sidebar'), findsOneWidget);
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
    expect(find.byType(TerminalView), findsOneWidget);

    // The pad floats over the terminal; arrows reach the PTY.
    expect(find.byTooltip('Up arrow'), findsOneWidget);
    final before = transport.sentBytes.length;
    await tester.tap(find.byTooltip('Up arrow'));
    await tester.pump(const Duration(milliseconds: 200));
    final arrowBytes = transport.sentBytes.sublist(before);
    expect(arrowBytes, contains(0x1b));
    expect(arrowBytes, contains(0x5b));

    // Dragging the pad border repositions it; a center drag must scroll
    // without moving the pad.
    final padRect = tester.getRect(find.byType(FloatingTerminalPad));
    await tester.dragFrom(
      Offset(padRect.right - 2, padRect.center.dy),
      const Offset(60, 80),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.getRect(find.byType(FloatingTerminalPad)).topLeft,
      isNot(padRect.topLeft),
    );

    // Tapping the pad's center logo opens the drawer on narrow layouts
    // (this regressed when the toggle closure captured a context above the
    // Scaffold); closing it again keeps the terminal interactive.
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Saved hosts'), findsOneWidget);
    // Dismiss the drawer by tapping the scrim to the right of it.
    await tester.tapAt(const Offset(389, 400));
    await tester.pump(const Duration(milliseconds: 300));

    // Terminal taps still reach flterm with the pad visible: a tap on the
    // terminal surface focuses it.
    final terminalRect = tester.getRect(find.byType(TerminalView));
    await tester.tapAt(
      Offset(terminalRect.right - 20, terminalRect.bottom - 20),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    final terminalElement = find.byType(TerminalView).evaluate().single;
    var focusedInsideTerminal = false;
    focused!.visitAncestorElements((Element ancestor) {
      if (identical(ancestor, terminalElement)) {
        focusedInsideTerminal = true;
        return false;
      }
      return true;
    });
    expect(focusedInsideTerminal, isTrue);
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
