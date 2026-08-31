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

/// Touch-shell coverage on the real app: the Linux build opts into the
/// touch layout via ZUKO_FORCE_TOUCH_PAD, so the pad, the missing top bar,
/// and the sidebar toggle can be driven on CI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('floating pad drives keys and the sidebar in the real app', (
    tester,
  ) async {
    final transport = LocalHostTransport();
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();

    // Touch shell: no app bar.
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.bySemanticsLabel(RegExp('Share code')),
      'alpha-bravo',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    // The connection opens asynchronously; poll instead of settling, since
    // the live btop output can keep frames scheduled indefinitely.
    for (
      var attempt = 0;
      attempt < 40 && find.byType(TerminalView).evaluate().isEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(TerminalView), findsOneWidget);

    // The pad floats over the terminal; arrows reach the PTY.
    expect(find.byTooltip('Up arrow'), findsOneWidget);
    final before = transport.sentBytes.length;
    await tester.tap(find.byTooltip('Up arrow'));
    await tester.pump(const Duration(milliseconds: 200));
    final arrowBytes = transport.sentBytes.sublist(before);
    expect(arrowBytes, contains(0x1b));
    expect(arrowBytes, contains(0x5b));

    // Dragging the pad repositions it.
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

    // Tapping the pad's center logo toggles the sidebar panel.
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved hosts'), findsOneWidget);
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved hosts'), findsNothing);

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
