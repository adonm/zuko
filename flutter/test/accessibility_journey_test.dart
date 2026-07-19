import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/storage.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

const _home = SavedHost(
  name: 'Home server',
  label: 'home',
  ticket: 'ticket-home',
  nodeId: 'node-home',
  authorizedClientLabel: 'zuko-linux-a1b2c3',
);
const _office = SavedHost(
  name: 'Office workstation',
  label: 'office',
  ticket: 'ticket-office',
  nodeId: 'node-office',
  authorizedClientLabel: 'zuko-linux-d4e5f6',
);

void main() {
  testWidgets('keyboard journey pairs the first host', (tester) async {
    final semantics = tester.ensureSemantics();
    _setSurface(tester, const Size(390, 844));
    final transport = _JourneyTransport();
    final controller = await _controller(transport: transport);

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    final enterCode = find.text('Enter code instead');
    await _focusWithTab(tester, enterCode);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Enter the share code'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Share code')), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'iridescent-hilton');
    await tester.pump();

    final pair = find.widgetWithText(FilledButton, 'Pair');
    await _focusWithTab(tester, pair);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();

    expect(controller.hosts, hasLength(1));
    expect(controller.hosts.single.name, 'Home server');
    expect(
      controller.hosts.single.authorizedClientLabel,
      controller.clientLabel,
    );
    expect(transport.claimedCodes, ['iridescent-hilton']);
    expect(transport.sessions, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    semantics.dispose();
  });

  testWidgets('host search, recovery, and terminal focus are accessible', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    _setSurface(tester, const Size(1280, 800));
    final transport = _JourneyTransport();
    final controller = await _controller(
      transport: transport,
      hosts: const [_office, _home],
      interfaceSize: AppInterfaceSize.comfortable,
    );

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    expect(find.text('Interface size'), findsOneWidget);
    expect(find.text('Comfortable'), findsOneWidget);
    final search = find.widgetWithText(TextField, 'Search hosts');
    await _focusWithTab(tester, search);
    await tester.enterText(search, 'home');
    await tester.pump();

    final resultSummary = tester.getSemantics(
      find.bySemanticsLabel(RegExp('1 matching host')),
    );
    expect(
      resultSummary.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(find.text('Home server'), findsOneWidget);
    expect(find.text('Office workstation'), findsNothing);

    await _focusWithTab(tester, find.text('Home server'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(transport.sessions, hasLength(1));

    transport.sessions.first.emitState(
      const SessionState.retrying('Connection lost. Retrying in 1s...'),
    );
    await tester.pump();
    await tester.pump();
    final retryMessage = tester.getSemantics(
      find.bySemanticsLabel('Connection lost. Retrying in 1s...'),
    );
    expect(
      retryMessage.getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );

    final retry = find.widgetWithText(FilledButton, 'Retry now');
    final retryNode = tester.getSemantics(retry);
    expect(
      retryNode.getSemanticsData().flagsCollection.isFocused,
      Tristate.isTrue,
    );
    expect(retryNode.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(retry).onPressed!.call();
      for (var turn = 0; turn < 20 && transport.sessions.length < 2; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    expect(transport.sessions, hasLength(2));
    expect(transport.sessions.first.closed, isTrue);

    transport.sessions.last.emitState(const SessionState.attached());
    transport.sessions.last.emitOutput('shell ready\r\n');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    final terminalFinder = find.bySemanticsLabel('Home server remote terminal');
    final terminal = tester.getSemantics(terminalFinder);
    final terminalData = terminal.getSemanticsData();
    expect(terminalData.value, contains('shell ready'));
    expect(terminalData.hasAction(SemanticsAction.tap), isTrue);
    expect(terminalData.hasAction(SemanticsAction.focus), isTrue);
    expect(terminalData.flagsCollection.isLiveRegion, isFalse);

    tester.binding.rootPipelineOwner.semanticsOwner!.performAction(
      terminal.id,
      SemanticsAction.focus,
    );
    await tester.pump();
    expect(
      tester
          .getSemantics(terminalFinder)
          .getSemanticsData()
          .flagsCollection
          .isFocused,
      Tristate.isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    semantics.dispose();
  });

  testWidgets('forget and revoke guidance remain distinct to keyboard users', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    _setSurface(tester, const Size(1280, 800));
    final transport = _JourneyTransport();
    final controller = await _controller(
      transport: transport,
      hosts: const [_home],
    );

    await tester.pumpWidget(ZukoApp(controller: controller));
    await tester.pump();
    final manage = find.byTooltip('Manage Home server');
    await _focusWithTab(tester, manage);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await _focusWithTab(tester, find.text('Details'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      find.text('To revoke this client, run on the host:'),
      findsOneWidget,
    );
    expect(find.text('zuko rm zuko-linux-a1b2c3'), findsOneWidget);
    expect(find.byTooltip('Copy revoke command'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await _focusWithTab(tester, manage);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await _focusWithTab(tester, find.text('Forget'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Forget Home server?'), findsOneWidget);
    expect(
      find.text(
        'This removes the host from this client only. It does not revoke '
        'this client on the host.',
      ),
      findsOneWidget,
    );
    await _focusWithTab(tester, find.widgetWithText(TextButton, 'Cancel'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.hosts, [_home]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    semantics.dispose();
  });
}

void _setSurface(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _focusWithTab(
  WidgetTester tester,
  Finder target, {
  int limit = 60,
}) async {
  expect(target, findsOneWidget);
  for (var step = 0; step < limit; step++) {
    if (_hasRelatedFocus(tester, target)) return;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  fail('Could not focus the target widget with $limit Tab presses.');
}

bool _hasRelatedFocus(WidgetTester tester, Finder target) {
  try {
    if (tester
            .getSemantics(target)
            .getSemanticsData()
            .flagsCollection
            .isFocused ==
        Tristate.isTrue) {
      return true;
    }
  } on Object {
    // Fall through to the element relationship for widgets without a node.
  }
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused is! Element) return false;
  for (final candidate in target.evaluate()) {
    if (identical(candidate, focused) || _isAncestor(candidate, focused)) {
      return true;
    }
  }
  return false;
}

bool _isAncestor(Element possibleAncestor, Element element) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (identical(ancestor, possibleAncestor)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

Future<AppController> _controller({
  required _JourneyTransport transport,
  List<SavedHost> hosts = const [],
  AppInterfaceSize interfaceSize = AppInterfaceSize.standard,
}) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: 'test-device',
    hosts: hosts,
    interfaceSize: interfaceSize,
  );
  final storage = _MemoryStorage();
  final store = ClientStateStore.withStorage(storage);
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: transport,
  );
}

final class _JourneyTransport implements ClientTransport {
  final List<String> claimedCodes = [];
  final List<_JourneySession> sessions = [];
  bool closed = false;

  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    claimedCodes.add(code);
    return const ClaimResult(
      label: 'Home server',
      ticket: 'ticket-home',
      nodeId: 'node-home',
    );
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
    final session = _JourneySession();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _JourneySession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  bool closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Stream<SessionState> get states => _states.stream;

  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  void emitOutput(String value) =>
      _output.add(Uint8List.fromList(utf8.encode(value)));

  void emitState(SessionState value) => _states.add(value);

  @override
  Future<void> send(List<int> bytes) async {}

  @override
  Future<void> resize(TerminalGeometry geometry) async {}

  @override
  Future<void> close() async {
    closed = true;
  }
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
