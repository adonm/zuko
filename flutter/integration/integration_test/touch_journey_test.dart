import 'package:flutter/material.dart' show AppBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/floating_terminal_pad.dart';

import 'journey.dart';
import 'local_host_transport.dart';

/// Touch journey on the real app: the Linux build opts into the touch
/// layout via ZUKO_FORCE_TOUCH_PAD, so the user can drive pad keys,
/// reposition the pad, open the sidebar from it, and still tap the
/// terminal itself.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('touch pad drives keys, moves, and keeps terminal tappable', (
    tester,
  ) async {
    final transport = LocalHostTransport();
    final controller = await testController(transport);
    addTearDown(controller.close);

    // Touch shell drops the top bar from the first frame.
    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    expect(find.byType(AppBar), findsNothing);

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

    // Tapping the pad's center logo toggles the sidebar panel.
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved hosts'), findsOneWidget);
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved hosts'), findsNothing);

    // Terminal taps still reach flterm with the pad visible: a tap on the
    // terminal surface focuses it.
    await expectTerminalFocused(tester);
  });
}
