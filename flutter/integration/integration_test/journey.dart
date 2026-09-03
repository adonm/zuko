import 'dart:typed_data';

import 'package:flterm/flterm.dart' show TerminalView;
import 'package:flutter/material.dart' show FilledButton;
import 'package:flutter/widgets.dart' show Element, FocusManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_overlay.dart';
import 'package:zuko/src/storage.dart';
import 'package:zuko/src/transport.dart';

import 'local_host_transport.dart';

/// Shared user-journey scaffolding for the integration suite.
///
/// Every journey test pairs through the real UI against a real local PTY and
/// then drives an experience — using the shell, tapping a TUI, rearranging
/// the touch pad — so assertions read as user-visible outcomes rather than
/// widget-tree details. This library holds the repeated preamble (storage,
/// controller, pairing, waiting, SGR parsing) in one place; journey files
/// only describe the experience under test.
///
/// This file defines no tests, so it is never run directly.
final class MemoryStorage implements SecureStateStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<AppController> testController(
  ClientTransport transport, {
  String clientName = 'integration',
  double? terminalFontSize,
}) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: clientName,
    hosts: const [],
    terminalFontSize: terminalFontSize ?? 10,
    terminalFontSizeCustomized: terminalFontSize != null,
  );
  final store = ClientStateStore.withStorage(MemoryStorage());
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: transport,
  );
}

/// A short settle for UI reactions (focus changes, key echoes).
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Polls [condition] on a frame cadence; live PTY output can keep frames
/// scheduled indefinitely, so this is used instead of pumpAndSettle.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  int tries = 40,
}) async {
  for (var i = 0; i < tries && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Pairs a host through the welcome and pairing screens, then waits until
/// the terminal is attached and interactive: the journey's starting point.
Future<void> pairThroughUi(
  WidgetTester tester,
  AppController controller, {
  String code = 'alpha-bravo',
}) async {
  await tester.pumpWidget(ZukoApp(controller: controller));
  await tester.pump();
  await tester.tap(find.text('Enter pairing code'));
  await settle(tester);
  final shareCode = find.bySemanticsLabel(RegExp('Share code'));
  expect(shareCode, findsOneWidget);
  await tester.enterText(shareCode, code);
  await settle(tester);
  await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
  // The claim resolves and the app opens the terminal automatically.
  await waitFor(tester, () => controller.hosts.isNotEmpty);
  expect(controller.hosts, hasLength(1));
  await waitFor(tester, () => find.byType(TerminalView).evaluate().isNotEmpty);
  expect(find.byType(TerminalView), findsOneWidget);
  // Wait until the attaching overlay clears so the terminal accepts input.
  await waitFor(tester, () => find.byType(SessionOverlay).evaluate().isEmpty);
  expect(find.byType(SessionOverlay), findsNothing);
}

/// Waits until the PTY program has drawn its first frame.
Future<void> waitForProgramOutput(
  WidgetTester tester,
  LocalHostTransport transport, {
  int tries = 60,
}) async {
  await waitFor(
    tester,
    () => transport.receivedBytes.contains(0x1b),
    tries: tries,
  );
  expect(transport.receivedBytes.contains(0x1b), isTrue);
}

/// Parses the first SGR mouse report (`ESC [ < Cb ; Cx ; Cy M/m`) in [bytes]
/// into its (column, row). Throws a TestFailure when none is present.
(int, int) parseFirstSgr(List<int> bytes) {
  for (var i = 0; i + 5 < bytes.length; i++) {
    if (bytes[i] != 0x1b || bytes[i + 1] != 0x5b || bytes[i + 2] != 0x3c) {
      continue;
    }
    final end = bytes.indexWhere((b) => b == 0x4d || b == 0x6d, i + 3);
    if (end < 0) continue;
    final parts = String.fromCharCodes(bytes.sublist(i + 3, end)).split(';');
    if (parts.length != 3) continue;
    final col = int.tryParse(parts[1]);
    final row = int.tryParse(parts[2]);
    if (col == null || row == null) continue;
    return (col, row);
  }
  throw TestFailure('no SGR mouse report in $bytes');
}

/// Taps the terminal at [at] and returns the reported (column, row) of the
/// resulting SGR mouse report: the "clicks land where you tap" primitive.
Future<(int, int)> tapCellSgr(
  WidgetTester tester,
  LocalHostTransport transport,
  Offset at,
) async {
  final before = transport.sentBytes.length;
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 300));
  return parseFirstSgr(transport.sentBytes.sublist(before));
}

/// Asserts a tap on the terminal surface focuses the terminal even with
/// overlays (like the floating pad) visible.
Future<void> expectTerminalFocused(WidgetTester tester) async {
  final terminalRect = tester.getRect(find.byType(TerminalView));
  await tester.tapAt(Offset(terminalRect.right - 20, terminalRect.bottom - 20));
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
}
