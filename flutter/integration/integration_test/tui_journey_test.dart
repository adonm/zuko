import 'package:flterm/flterm.dart' show TerminalView;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'journey.dart';
import 'local_host_transport.dart';

/// TUI journey against a real mouse-capable program: yazi enables mouse
/// tracking, so the user can click it, long-press to arm local selection,
/// and rely on the Kitty graphics adapter for image previews.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('yazi answers clicks and long-press selects text', (
    tester,
  ) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'yazi'],
    );
    final controller = await testController(transport);
    addTearDown(controller.close);
    await pairThroughUi(tester, controller);

    // Let yazi draw and enable mouse tracking.
    await waitForProgramOutput(tester, transport, tries: 40);
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

  testWidgets('yazi clicks land on exact cells', (tester) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'yazi'],
    );
    final controller = await testController(transport);
    addTearDown(controller.close);
    await pairThroughUi(tester, controller);

    await waitForProgramOutput(tester, transport, tries: 40);
    await tester.pump(const Duration(milliseconds: 400));

    // Clicks land where you tap: the grid corner reports cell 1,1, reports
    // grow monotonically across the grid, and one spot reports one cell.
    final terminalRect = tester.getRect(find.byType(TerminalView));
    final (col, row) = await tapCellSgr(
      tester,
      transport,
      terminalRect.topLeft + const Offset(1, 1),
    );
    expect(col, 1);
    expect(row, 1);

    final (leftCol, _) = await tapCellSgr(
      tester,
      transport,
      Offset(
        terminalRect.left + terminalRect.width * 0.1,
        terminalRect.top + terminalRect.height * 0.5,
      ),
    );
    final (rightCol, _) = await tapCellSgr(
      tester,
      transport,
      Offset(
        terminalRect.left + terminalRect.width * 0.9,
        terminalRect.top + terminalRect.height * 0.5,
      ),
    );
    expect(rightCol, greaterThan(leftCol));
    final (_, topRow) = await tapCellSgr(
      tester,
      transport,
      Offset(
        terminalRect.left + terminalRect.width * 0.5,
        terminalRect.top + terminalRect.height * 0.2,
      ),
    );
    final (_, bottomRow) = await tapCellSgr(
      tester,
      transport,
      Offset(
        terminalRect.left + terminalRect.width * 0.5,
        terminalRect.top + terminalRect.height * 0.8,
      ),
    );
    expect(bottomRow, greaterThan(topRow));

    final spot = Offset(
      terminalRect.left + terminalRect.width * 0.4,
      terminalRect.top + terminalRect.height * 0.6,
    );
    expect(
      await tapCellSgr(tester, transport, spot),
      await tapCellSgr(tester, transport, spot),
    );
  });

  testWidgets('yazi picks the Kitty graphics adapter', (tester) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'ya env'],
    );
    final controller = await testController(transport);
    addTearDown(controller.close);
    await pairThroughUi(tester, controller);

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
