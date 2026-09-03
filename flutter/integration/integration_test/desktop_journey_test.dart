import 'package:flterm/flterm.dart' show TerminalView;
import 'package:flutter/material.dart' show OutlinedButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'journey.dart';
import 'local_host_transport.dart';

/// Desktop journey on the real app: pair through the UI, use a real shell
/// (latched Ctrl keys, arrows, settings), then disconnect — plus a btop
/// session proving TUI clicks land on exact cells.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pair, use the shell, and disconnect', (tester) async {
    final transport = LocalHostTransport();
    final controller = await testController(transport);
    addTearDown(controller.close);
    await pairThroughUi(tester, controller);

    // The terminal surface is visible with the accessory key row.
    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);

    // A real bash PTY is attached: wait for the prompt to arrive.
    await waitFor(tester, () => transport.receivedBytes.isNotEmpty);
    expect(transport.receivedBytes, isNotEmpty);

    // Latch Ctrl, focus the terminal, then a hardware 'c' must merge into
    // Ctrl+C (0x03) on the wire.
    await tester.tap(find.text('Ctrl'));
    await settle(tester);
    await tester.tap(find.byType(TerminalView));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await settle(tester);
    expect(transport.sentBytes, contains(0x03));

    // Accessory arrow keys send real escape sequences.
    await tester.tap(find.byTooltip('Up').first);
    await settle(tester);
    expect(
      transport.sentBytes
          .where((byte) => byte == 0x1b || byte == 0x5b || byte == 0x41)
          .length,
      greaterThanOrEqualTo(3),
    );

    // Sidebar settings toggles update controller state and UI. The wide
    // sidebar starts as a collapsed rail; the accessory logo expands it.
    await tester.tap(find.byTooltip('Toggle sidebar'));
    await settle(tester);
    await tester.tap(find.text('Open keyboard on tap'));
    await settle(tester);
    expect(controller.keyboardOnTap, isTrue);

    // Disconnect from the sidebar closes the session and kills the PTY.
    // The button sits at the bottom of the sidebar list; drag the sidebar
    // up until it builds.
    for (
      var attempt = 0;
      attempt < 10 &&
          find.widgetWithText(OutlinedButton, 'Disconnect').evaluate().isEmpty;
      attempt++
    ) {
      await tester.dragFrom(const Offset(150, 480), const Offset(0, -120));
      await settle(tester);
    }
    await tester.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(transport.hasLiveSessions, isFalse);
  });

  testWidgets('btop renders and clicks land on exact cells', (tester) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'btop'],
    );
    final controller = await testController(transport);
    addTearDown(controller.close);
    await pairThroughUi(tester, controller);

    // Give btop time to draw frames; flterm must receive ANSI escape
    // sequences and TUI content from the PTY. The first paint can be slow
    // on cold machines, so poll generously.
    await waitForProgramOutput(tester, transport);
    expect(transport.receivedBytes.length, greaterThan(100));

    // The terminal widget is alive and connected to a controller.
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminal.controller, isNotNull);

    // Clicks land where you tap: the grid corner reports cell 1,1 and a
    // center tap reports a cell inside the grid.
    final terminalRect = tester.getRect(find.byType(TerminalView));
    final (cornerCol, cornerRow) = await tapCellSgr(
      tester,
      transport,
      terminalRect.topLeft + const Offset(1, 1),
    );
    expect(cornerCol, 1);
    expect(cornerRow, 1);
    final (centerCol, centerRow) = await tapCellSgr(
      tester,
      transport,
      terminalRect.center,
    );
    expect(centerCol, greaterThan(1));
    expect(centerRow, greaterThan(1));
  });
}
