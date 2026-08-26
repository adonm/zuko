import 'dart:async';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' show Key;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/extended_key_palette.dart';
import 'package:zuko/src/repeatable_action.dart';
import 'package:zuko/src/accessory_bar.dart';
import 'package:zuko/src/sidebar.dart';
import 'package:zuko/src/terminal_key_lists.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/storage.dart';
import 'package:zuko/src/theme.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/window_frame.dart';
import 'package:zuko/src/wire.dart';

void main() {
  test('terminal accessory controls use standard Adwaita dimensions', () {
    const metrics = ZukoMetrics.standard();

    expect(metrics.terminalAccessoryHeight, 34);
    expect(metrics.terminalAccessoryItemWidth, 34);
    expect(metrics.terminalAccessorySlimHeight, 28);
    expect(metrics.terminalAccessoryGroupSpacing, 6);
  });

  test('mobile accessory collapses while the soft keyboard is closed', () {
    expect(
      terminalAccessoryMode(keyboardVisible: false, mobile: true),
      TerminalAccessoryMode.slim,
    );
    expect(
      terminalAccessoryMode(keyboardVisible: true, mobile: true),
      TerminalAccessoryMode.full,
    );
    expect(
      terminalAccessoryMode(keyboardVisible: false, mobile: false),
      TerminalAccessoryMode.full,
    );
  });

  test('terminal navigation keys use predictable paired ordering', () {
    expect(terminalArrowKeys.map((item) => item.label), [
      'Up',
      'Down',
      'Left',
      'Right',
    ]);
    expect(terminalNavigationKeys.map((item) => item.label), [
      'Home',
      'End',
      'Page Up',
      'Page Down',
      'Insert',
      'Delete',
    ]);
    expect(terminalFunctionKeys.map((item) => item.label), [
      for (var index = 1; index <= 12; index++) 'F$index',
    ]);
  });

  test('connection tabs are only useful for parallel sessions', () {
    expect(showConnectionTabs(0), isFalse);
    expect(showConnectionTabs(1), isFalse);
    expect(showConnectionTabs(2), isTrue);
  });

  test('touch scrolls until text selection is explicitly enabled', () {
    final scrolling = terminalGestureSettings(touchSelectionEnabled: false);
    final selecting = terminalGestureSettings(touchSelectionEnabled: true);

    expect(scrolling.longPressSelection, isFalse);
    expect(selecting.longPressSelection, isTrue);
    expect(scrolling.dragSelection, isTrue);
    expect(selecting.dragSelection, isTrue);
  });

  test('Linux routes touch-as-mouse drags to scrolling', () {
    final linux = terminalGestureSettings(
      touchSelectionEnabled: false,
      platform: TargetPlatform.linux,
    );
    final android = terminalGestureSettings(touchSelectionEnabled: false);

    expect(linux.dragSelection, isFalse);
    expect(android.dragSelection, isTrue);
    expect(linux.longPressSelection, android.longPressSelection);
  });

  test('Linux scroll behavior accepts every pointer kind for dragging', () {
    const behavior = ZukoScrollBehavior();
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
    expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
    expect(behavior.dragDevices, contains(PointerDeviceKind.trackpad));
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
    expect(find.byType(FilledButton), findsNWidgets(18));
    expect(find.byType(OutlinedButton), findsNothing);
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

  testWidgets('moving after a terminal action detaches does not throw', (
    tester,
  ) async {
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return visible
                  ? RepeatableAction(
                      onInvoke: () => update(() => visible = false),
                      child: const SizedBox(width: 48, height: 48),
                    )
                  : const SizedBox();
            },
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(RepeatableAction)),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await gesture.cancel();
  });

  test('screens use responsive defaults until the user chooses a size', () {
    expect(
      effectiveTerminalFontSize(
        wideLayout: false,
        configuredSize: 14,
        customized: false,
      ),
      7,
    );
    expect(
      effectiveTerminalFontSize(
        wideLayout: true,
        configuredSize: 14,
        customized: false,
      ),
      10,
    );
    expect(
      effectiveTerminalFontSize(
        wideLayout: false,
        configuredSize: 9,
        customized: true,
      ),
      9,
    );
  });

  test('sidebar breakpoint preserves usable main-pane width at every size', () {
    const compact = ZukoMetrics.compact();
    const standard = ZukoMetrics.standard();
    const comfortable = ZukoMetrics.comfortable();

    expect(compact.wideLayoutBreakpoint, 730);
    expect(standard.wideLayoutBreakpoint, 760);
    expect(comfortable.wideLayoutBreakpoint, 805);
    for (final metrics in [compact, standard, comfortable]) {
      expect(
        metrics.wideLayoutBreakpoint - metrics.sidebarWidth,
        ZukoMetrics.minimumMainPaneWidth,
      );
    }
  });

  test('Linux always uses the integrated Yaru window title bar', () {
    expect(
      usesYaruWindowTitleBar(platform: TargetPlatform.linux, isWeb: false),
      isTrue,
    );
    for (final width in [390.0, 1280.0]) {
      expect(
        usesIntegratedDesktopHeader(
          wideLayout: width >= 760,
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
          wideLayout: true,
          platform: platform,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        usesIntegratedDesktopHeader(
          wideLayout: false,
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
        wideLayout: true,
        platform: TargetPlatform.linux,
        isWeb: true,
      ),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        wideLayout: true,
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isFalse,
    );
  });

  _accessoryWidgetTests();
}

Future<AppController> _accessoryTestController() async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: 'test-device',
    hosts: const [
      SavedHost(
        name: 'Home server',
        label: 'home',
        ticket: 'ticket-home',
        nodeId: 'node-home',
      ),
    ],
  );
  final storage = _AccessoryTestStorage();
  final store = ClientStateStore.withStorage(storage);
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: _AccessoryTestTransport(),
  );
}

final class _AccessoryTestTransport implements ClientTransport {
  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    throw UnimplementedError();
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
    final session = _AccessoryTestSession();
    session.emitState(const SessionState.attached());
    return session;
  }

  @override
  Future<void> close() async {}
}

final class _AccessoryTestSession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  void emitState(SessionState value) => _states.add(value);

  @override
  Future<void> send(List<int> bytes) async {}

  @override
  Future<void> resize(TerminalGeometry geometry) async {}

  @override
  Future<void> close() async {}
}

final class _AccessoryTestStorage implements SecureStateStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void _setAccessorySurface(
  WidgetTester tester, {
  Size size = const Size(390, 844),
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void _setAccessoryPlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
}

Future<void> _pumpFrames(WidgetTester tester) async {
  // Run one fake-async frame, then let real async work (ink ripples, drawer
  // and implicit animations) settle on the real event loop. Settling first
  // prevents flterm's idle compression task from being deferred forever by
  // an in-flight animation, which would spin the scheduler's zero-delay
  // event-loop callback until the test timed out.
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 400)),
  );
  await tester.pump();
}

void _accessoryWidgetTests() {
  testWidgets(
    'mobile accessory keeps quick actions while the keyboard is closed',
    (tester) async {
      _setAccessorySurface(tester, size: const Size(1200, 800));
      _setAccessoryPlatform(TargetPlatform.android);
      final controller = await _accessoryTestController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(ZukoApp(controller: controller));
      await _pumpFrames(tester);

      await tester.tap(find.text('Home server'));
      await _pumpFrames(tester);

      // Soft keyboard closed: the slim row keeps only quick actions.
      expect(find.text('Esc'), findsNothing);
      expect(find.text('Tab'), findsNothing);
      expect(find.text('Ctrl'), findsNothing);
      expect(find.byTooltip('Show keyboard'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('mobile accessory shows typing keys above the open keyboard', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.android);
    // Present the soft keyboard before the app builds so the accessory
    // mounts directly in full mode.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.text('Tab'), findsNothing); // Tab lives in the menu on mobile
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop accessory keeps the full row without a keyboard', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.linux);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Tab'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.byTooltip('Enable touch text selection'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
