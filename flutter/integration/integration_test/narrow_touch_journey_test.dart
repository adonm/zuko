import 'package:flutter/material.dart' show AppBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/floating_terminal_pad.dart';

import 'journey.dart';
import 'local_host_transport.dart';

/// Narrow touch journey on the real app: the runner sizes the window from
/// ZUKO_WINDOW_SIZE (390x844 here) and ZUKO_FORCE_TOUCH_PAD opts into the
/// touch layout, so the user can open the drawer from the corner logo, drive
/// pad keys, and still tap the terminal at phone dimensions.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('narrow layout: drawer, pad keys, tappable terminal', (
    tester,
  ) async {
    final transport = LocalHostTransport();
    final controller = await testController(transport);
    addTearDown(controller.close);

    // Before any terminal opens, the floating corner logo is the only
    // sidebar access on narrow touch layouts.
    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Open sidebar'), findsOneWidget);

    await pairThroughUi(tester, controller);

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

    // Terminal taps still reach flterm with the pad visible.
    await expectTerminalFocused(tester);
  });
}
