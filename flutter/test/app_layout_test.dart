import 'dart:async';
import 'dart:typed_data';

import 'package:flterm/flterm.dart' show Mods, TerminalController, TerminalView;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide Key;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/floating_terminal_pad.dart';
import 'package:zuko/src/repeatable_action.dart';
import 'package:zuko/src/sidebar.dart';
import 'package:zuko/src/terminal_key_lists.dart';
import 'package:zuko/src/accessory_bar.dart';
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
    expect(metrics.terminalAccessoryGroupSpacing, 6);
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
      'PgUp',
      'PgDn',
      'Ins',
      'Del',
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

  test('Linux narrow layouts keep the app bar and wide ones integrate', () {
    expect(
      usesIntegratedDesktopHeader(
        wideLayout: false,
        platform: TargetPlatform.linux,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        wideLayout: true,
        platform: TargetPlatform.linux,
        isWeb: false,
      ),
      isTrue,
    );
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

Future<void> _expandSidebar(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Expand sidebar'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
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
  testWidgets('floating pad sends keys and drags from its border', (
    tester,
  ) async {
    final controller = TerminalController();
    final sent = <int>[];
    controller.onOutput = (bytes) => sent.addAll(bytes);
    var dragged = false;
    var toggled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 10,
                top: 10,
                child: FloatingTerminalPad(
                  controller: controller,
                  onDragged: (_) => dragged = true,
                  onToggleSidebar: () => toggled = true,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Up arrow'));
    // ESC [ A escape sequence reaches the terminal input.
    expect(sent, [0x1b, 0x5b, 0x41]);
    await tester.tap(find.byTooltip('Open sidebar'));
    expect(toggled, isTrue);
    await tester.tap(find.byTooltip('Home'));
    // ESC [ H escape sequence for the Home key.
    expect(sent, [0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x48]);

    // Dragging the pad repositions it.
    final rect = tester.getRect(find.byType(FloatingTerminalPad));
    await tester.dragFrom(
      Offset(rect.right - 2, rect.center.dy),
      const Offset(30, 40),
    );
    expect(dragged, isTrue);
    dragged = false;

    // Latched accessory mods merge into pad keys: Ctrl+Shift+Up encodes as
    // CSI 1;6A.
    sent.clear();
    controller.toggleMod(const Mods.ctrl() | Mods.shift());
    await tester.tap(find.byTooltip('Up arrow'));
    expect(sent, [0x1b, 0x5b, 0x31, 0x3b, 0x36, 0x41]);
  });

  testWidgets('terminal taps still reach flterm on touch with the pad', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(390, 844));
    _setAccessoryPlatform(TargetPlatform.android);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await tester.tap(find.byTooltip('Open sidebar'));
    // The drawer slides in on fake time; settle it before tapping the host.
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    // Tap the terminal far from the pad: the tap must focus the terminal,
    // proving the pad does not swallow terminal clicks.
    final terminalRect = tester.getRect(find.byType(TerminalView));
    await tester.tapAt(
      Offset(terminalRect.right - 20, terminalRect.bottom - 20),
    );
    await _pumpFrames(tester);
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    final terminalElement = find.byType(TerminalView).evaluate().single;
    var focusedInsideTerminal = false;
    focused!.visitAncestorElements((ancestor) {
      if (identical(ancestor, terminalElement)) {
        focusedInsideTerminal = true;
        return false;
      }
      return true;
    });
    expect(focusedInsideTerminal, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('multiline paste asks before sending', (tester) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.linux);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);
    await _expandSidebar(tester);
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{
          'text': 'ls -la\nrm -rf /tmp/zuko-paste-test\n',
        };
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    // Cancel keeps the guarded paste off the wire.
    await tester.tap(find.byTooltip('Paste'));
    await _pumpFrames(tester);
    expect(find.text('Paste potentially unsafe text?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _pumpFrames(tester);
    expect(find.text('Paste potentially unsafe text?'), findsNothing);

    // Confirming sends the guarded paste.
    await tester.tap(find.byTooltip('Paste'));
    await _pumpFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
    await _pumpFrames(tester);
    expect(find.text('Paste potentially unsafe text?'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow pad center tap opens the drawer', (tester) async {
    _setAccessorySurface(tester, size: const Size(390, 844));
    _setAccessoryPlatform(TargetPlatform.android);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    // Open the host through the corner logo and the drawer.
    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    // The pad's center logo opens the drawer on narrow touch layouts; this
    // regressed when the toggle closure captured a context above the
    // Scaffold. Frames are pumped explicitly because the open terminal's
    // idle compression task never settles.
    await tester.tap(find.byTooltip('Open sidebar'));
    await _pumpFrames(tester);
    expect(find.textContaining('Saved hosts'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow touch opens the drawer from the floating logo', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(390, 844));
    _setAccessoryPlatform(TargetPlatform.android);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    expect(find.byTooltip('Open sidebar'), findsOneWidget);
    await tester.tap(find.byTooltip('Open sidebar'));
    await _pumpFrames(tester);
    expect(find.text('Home server'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('landscape safe area insets the terminal for the island', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(844, 390));
    _setAccessoryPlatform(TargetPlatform.iOS);
    tester.view.padding = const FakeViewPadding(
      left: 47,
      top: 0,
      right: 47,
      bottom: 21,
    );
    addTearDown(tester.view.resetPadding);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await _expandSidebar(tester);
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    // The whole body row is inset on both sides like native apps in
    // landscape: the expanded sidebar starts past the left inset and the
    // terminal ends before the right inset. The floating pad is present on
    // touch platforms.
    final topLeft = tester.getTopLeft(find.byType(TerminalView));
    final bottomRight = tester.getBottomRight(find.byType(TerminalView));
    expect(topLeft.dx, 47 + 300 + 1); // inset + sidebar + divider
    expect(bottomRight.dx, 844 - 47);
    expect(topLeft.dy, greaterThanOrEqualTo(0));
    expect(find.byTooltip('Up arrow'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('accessory keeps the fixed key row on mobile', (tester) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.android);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await _expandSidebar(tester);
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Tab'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
    expect(find.text('Alt'), findsOneWidget);
    expect(find.byTooltip('Select all'), findsOneWidget);
    // Arrows moved to the floating pad on touch platforms.
    expect(find.byTooltip('Up'), findsNothing);
    expect(find.byTooltip('Up arrow'), findsOneWidget);
    // The accessory logo is desktop-only; on touch the pad's center logo
    // opens the sidebar.
    expect(find.byTooltip('Toggle sidebar'), findsNothing);
    expect(find.byTooltip('Open sidebar'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('desktop accessory holds every key group in one strip', (
    tester,
  ) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.linux);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await _expandSidebar(tester);
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    // One horizontally scrolling strip: logo, core keys, punctuation,
    // navigation, and function keys. The ListView lazily builds off-screen
    // children, so assert the delegate's item count covers every group.
    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(TerminalAccessory),
        matching: find.byType(ListView),
      ),
    );
    final count = list.childrenDelegate.estimatedChildCount;
    expect(
      count,
      1 + // sidebar logo
          5 + // Esc, Tab, Ctrl, Alt, Shift
          4 + // arrows
          2 + // copy/paste and select-all
          terminalPunctuationKeys.length +
          terminalNavigationKeys.length +
          terminalFunctionKeys.length +
          7, // group spacers
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('touch accessory omits keys the soft keyboard provides', (
    tester,
  ) async {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      _setAccessorySurface(tester, size: const Size(1200, 800));
      _setAccessoryPlatform(platform);
      final controller = await _accessoryTestController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(ZukoApp(controller: controller));
      await _pumpFrames(tester);

      await _expandSidebar(tester);
      await tester.tap(find.text('Home server'));
      await _pumpFrames(tester);

      // Core keys stay; punctuation is covered by the soft keyboard's
      // number and symbol layers, and arrows plus navigation keys moved to
      // the floating pad.
      expect(find.text('Esc'), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.byTooltip('Select all'), findsOneWidget);
      expect(find.text('|'), findsNothing);
      expect(find.text('~'), findsNothing);
      expect(find.text('>'), findsNothing);
      expect(find.text('Home'), findsNothing);
      expect(find.byTooltip('Home'), findsOneWidget);
      expect(find.byTooltip('Up arrow'), findsOneWidget);
      expect(find.byTooltip('Open sidebar'), findsOneWidget);
      expect(find.byTooltip('Toggle sidebar'), findsNothing);

      final list = tester.widget<ListView>(
        find.descendant(
          of: find.byType(TerminalAccessory),
          matching: find.byType(ListView),
        ),
      );
      expect(
        list.childrenDelegate.estimatedChildCount,
        5 + // Esc, Tab, Ctrl, Alt, Shift
            2 + // copy/paste and select-all
            terminalFunctionKeys.length +
            4, // group spacers
      );

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('desktop accessory keeps the fixed key row', (tester) async {
    _setAccessorySurface(tester, size: const Size(1200, 800));
    _setAccessoryPlatform(TargetPlatform.linux);
    final controller = await _accessoryTestController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await _pumpFrames(tester);

    await _expandSidebar(tester);
    await tester.tap(find.text('Home server'));
    await _pumpFrames(tester);

    expect(find.text('Esc'), findsOneWidget);
    expect(find.text('Tab'), findsOneWidget);
    expect(find.text('Ctrl'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
