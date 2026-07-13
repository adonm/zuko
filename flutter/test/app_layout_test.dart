import 'package:flterm/flterm.dart' show Key;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/window_frame.dart';

void main() {
  test('terminal accessory row is half the previous height', () {
    expect(terminalAccessoryHeight, 24);
  });

  test('terminal accessory controls fit normal narrow screens', () {
    expect(
      terminalAccessoryItemWidth(availableWidth: 390, itemCount: 11),
      closeTo(34.73, 0.01),
    );
    expect(
      terminalAccessoryItemWidth(availableWidth: 320, itemCount: 11),
      closeTo(28.36, 0.01),
    );
    expect(terminalAccessoryItemWidth(availableWidth: 1280, itemCount: 11), 36);
  });

  test('saved host search matches identity fields and multiple terms', () {
    const host = SavedHost(
      name: 'Office workstation',
      label: 'dev-box',
      ticket: 'ticket',
      nodeId: 'abc123def456',
    );

    expect(savedHostMatchesQuery(host, ''), isTrue);
    expect(savedHostMatchesQuery(host, 'OFFICE'), isTrue);
    expect(savedHostMatchesQuery(host, 'dev-box'), isTrue);
    expect(savedHostMatchesQuery(host, '123def'), isTrue);
    expect(savedHostMatchesQuery(host, 'office dev-box'), isTrue);
    expect(savedHostMatchesQuery(host, 'office home'), isFalse);
  });

  testWidgets('saved host list filters visible rows and clears', (
    tester,
  ) async {
    const hosts = [
      SavedHost(
        name: 'Office workstation',
        label: 'dev-box',
        ticket: 'ticket-a',
        nodeId: 'aaa111',
      ),
      SavedHost(
        name: 'Home server',
        label: 'nas',
        ticket: 'ticket-b',
        nodeId: 'bbb222',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SavedHostList(
              hosts: hosts,
              selected: null,
              onConnect: (_) {},
              onAction: (_, _) {},
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Search hosts'),
      'nas',
    );
    await tester.pump();

    expect(find.text('Home server'), findsOneWidget);
    expect(find.text('Office workstation'), findsNothing);

    await tester.tap(find.byTooltip('Clear host search'));
    await tester.pump();
    expect(find.text('Home server'), findsOneWidget);
    expect(find.text('Office workstation'), findsOneWidget);
  });

  testWidgets('device name dialog validates and returns normalized name', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDeviceNameDialog(
                  context,
                  initialName: 'old-name',
                );
              },
              child: const Text('Edit name'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '---');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter letters or numbers.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Office iPad');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'office-ipad');
  });

  testWidgets('extended key palette sends typed terminal keys', (tester) async {
    final keys = <Key>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalExtendedKeyPalette(onKey: keys.add)),
      ),
    );

    await tester.tap(find.text('Page Up'));
    await tester.tap(find.text('F12'));

    expect(keys, [Key.pageUp, Key.f12]);
  });

  testWidgets('held terminal actions repeat after a deliberate delay', (
    tester,
  ) async {
    var invocations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Material(
              child: RepeatableAction(
                onInvoke: () => invocations++,
                child: const SizedBox(width: 48, height: 48),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RepeatableAction)),
    );
    expect(invocations, 1);
    await tester.pump(const Duration(milliseconds: 399));
    expect(invocations, 1);
    await tester.pump(const Duration(milliseconds: 161));
    expect(invocations, 4);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 160));
    expect(invocations, 4);
  });

  testWidgets('leaving a terminal action stops future repeats', (tester) async {
    var invocations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Material(
              child: RepeatableAction(
                onInvoke: () => invocations++,
                child: const SizedBox(width: 48, height: 48),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RepeatableAction)),
    );
    expect(invocations, 1);
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    expect(invocations, 1);
  });

  testWidgets('canceled terminal action stops future repeats', (tester) async {
    var invocations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Material(
              child: RepeatableAction(
                onInvoke: () => invocations++,
                child: const SizedBox(width: 100, height: 48),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RepeatableAction)),
    );
    expect(invocations, 1);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    expect(invocations, 1);
  });

  testWidgets('disposing a held terminal action cancels repeat', (
    tester,
  ) async {
    var invocations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Material(
            child: RepeatableAction(
              onInvoke: () => invocations++,
              child: const SizedBox(width: 48, height: 48),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RepeatableAction)),
    );
    expect(invocations, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 600));
    expect(invocations, 1);
    await gesture.cancel();
  });

  test('screens use responsive defaults until the user chooses a size', () {
    expect(
      effectiveTerminalFontSize(
        width: 390,
        configuredSize: 14,
        customized: false,
      ),
      7,
    );
    expect(
      effectiveTerminalFontSize(
        width: 1280,
        configuredSize: 14,
        customized: false,
      ),
      10,
    );
    expect(
      effectiveTerminalFontSize(
        width: 390,
        configuredSize: 9,
        customized: true,
      ),
      9,
    );
  });

  test('Linux always uses the integrated Yaru window title bar', () {
    expect(
      usesYaruWindowTitleBar(platform: TargetPlatform.linux, isWeb: false),
      isTrue,
    );
    for (final width in [390.0, 1280.0]) {
      expect(
        usesIntegratedDesktopHeader(
          width: width,
          platform: TargetPlatform.linux,
          isWeb: false,
        ),
        isTrue,
      );
    }
  });

  test('wide macOS and Windows layouts keep their native title bars', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      expect(
        usesIntegratedDesktopHeader(
          width: 1280,
          platform: platform,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        usesIntegratedDesktopHeader(
          width: 759,
          platform: platform,
          isWeb: false,
        ),
        isFalse,
      );
    }
  });

  test('web and mobile layouts keep the Flutter app bar', () {
    expect(
      usesYaruWindowTitleBar(platform: TargetPlatform.linux, isWeb: true),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        width: 1280,
        platform: TargetPlatform.linux,
        isWeb: true,
      ),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        width: 1280,
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isFalse,
    );
  });
}
