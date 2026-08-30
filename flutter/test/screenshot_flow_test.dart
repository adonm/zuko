// Screenshot generation for the pair/connect flow.
//
// This test renders the real Zuko UI (Material themes, bundled fonts, window
// frame, terminal widget) into PNG images under `docs/images/` for the
// mdBook pairing flow page. It only
// writes files when requested, so the normal gate stays fast and hermetic:
//
//   flutter test test/screenshot_flow_test.dart --dart-define=SCREENSHOTS=true
//
// Regenerate the screenshots whenever the pairing or connection UI changes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/pairing_screen.dart';
import 'package:zuko/src/session_state.dart';
import 'package:zuko/src/storage.dart';
import 'package:zuko/src/theme.dart';
import 'package:zuko/src/transport.dart';
import 'package:zuko/src/wire.dart';

const _generate = bool.fromEnvironment('SCREENSHOTS');

const _desktop = Size(1400, 900);
const _portrait = Size(440, 900);

const _host = SavedHost(
  name: 'workstation',
  label: 'office',
  ticket: 'ticket',
  nodeId: 'node',
);

final _shotKey = GlobalKey();

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  void useLinuxPlatform() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  group('pair and connect flow screenshots', () {
    testWidgets('welcome screen', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _desktop, 2.0);
      final controller = await _controller(_FakeTransport());
      await controller.setTheme(AppThemePreference.dark);
      await tester.pumpWidget(_shot(ZukoApp(controller: controller)));
      await _capture(tester, 'welcome');
      await _unmount(tester, controller);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('manual pairing screen', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _portrait, 2.0);
      await tester.pumpWidget(
        _shot(
          _themed(
            PairingScreen(startInManual: true, onClaim: (_) async => _host),
          ),
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'iridescent-hilton');
      await _capture(tester, 'pairing-code');
      await _unmountTree(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('camera pairing screen', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _portrait, 2.0);
      await tester.pumpWidget(
        _shot(
          _themed(
            PairingScreen(
              scannerAvailable: true,
              scannerBuilder: (context, onDetect) => const _FakeCameraPreview(),
              onClaim: (_) async => _host,
            ),
          ),
        ),
      );
      await _pumpFrames(tester, 6);
      await _capture(tester, 'pairing-scan');
      await _unmountTree(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('pairing success confirmation', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _portrait, 2.0);
      final gate = Completer<SavedHost>();
      await tester.pumpWidget(
        _shot(
          _themed(
            PairingScreen(startInManual: true, onClaim: (_) => gate.future),
          ),
        ),
      );
      await tester.enterText(find.byType(TextFormField), 'iridescent-hilton');
      await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
      await tester.pump();
      gate.complete(_host);
      await _pumpFrames(tester, 3);
      await _capture(tester, 'pairing-confirmed');
      await _unmountTree(tester);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('connecting to a saved host', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _desktop, 2.0);
      final transport = _FakeTransport();
      final controller = await _controller(transport, hosts: const [_host]);
      await controller.setTheme(AppThemePreference.dark);
      await tester.pumpWidget(_shot(ZukoApp(controller: controller)));
      await tester.tap(find.byTooltip('Expand sidebar'));
      await _pumpFrames(tester, 3);
      final hostTile = find.widgetWithText(ListTile, 'workstation');
      await tester.ensureVisible(hostTile);
      tester.widget<ListTile>(hostTile).onTap!();
      await _pumpFrames(tester, 1);
      await _pumpFrames(tester, 6);
      await _capture(tester, 'connecting');
      await _unmount(tester, controller);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('automatic retry countdown', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _desktop, 2.0);
      final transport = _FakeTransport();
      final controller = await _controller(transport, hosts: const [_host]);
      await controller.setTheme(AppThemePreference.dark);
      await tester.pumpWidget(_shot(ZukoApp(controller: controller)));
      await tester.tap(find.byTooltip('Expand sidebar'));
      await _pumpFrames(tester, 3);
      final hostTile = find.widgetWithText(ListTile, 'workstation');
      await tester.ensureVisible(hostTile);
      tester.widget<ListTile>(hostTile).onTap!();
      await _pumpFrames(tester, 1);
      await _pumpFrames(tester, 3);
      transport.sessions.single.emitState(
        const SessionState.retrying(
          'Connection lost. Retrying…',
          retryAfter: Duration(seconds: 4),
        ),
      );
      await _pumpFrames(tester, 24);
      await _capture(tester, 'retrying');
      await _unmount(tester, controller);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('attached terminal session', (tester) async {
      if (!_generate) return;
      useLinuxPlatform();
      await _setSurface(tester, _desktop, 2.0);
      final transport = _FakeTransport();
      final controller = await _controller(transport, hosts: const [_host]);
      await controller.setTheme(AppThemePreference.dark);
      await tester.pumpWidget(_shot(ZukoApp(controller: controller)));
      await tester.tap(find.byTooltip('Expand sidebar'));
      await _pumpFrames(tester, 3);
      final hostTile = find.widgetWithText(ListTile, 'workstation');
      await tester.ensureVisible(hostTile);
      tester.widget<ListTile>(hostTile).onTap!();
      await _pumpFrames(tester, 1);
      await _pumpFrames(tester, 3);
      final session = transport.sessions.single;
      session.emitState(const SessionState.attached());
      session.emitOutput(_shellOutput);
      await _pumpFrames(tester, 6);
      await _capture(tester, 'connected');
      await _unmount(tester, controller);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

const _shellOutput =
    '\r\n'
    '\x1b[1;32madonm@workstation\x1b[0m:\x1b[1;34m~\x1b[0m\$ zuko ls\r\n'
    '  workstation  office  \x1b[1;32mattached\x1b[0m\r\n'
    '\r\n'
    '\x1b[1;32madonm@workstation\x1b[0m:\x1b[1;34m~\x1b[0m\$ uname -a\r\n'
    'Linux workstation 6.8.0 x86_64 GNU/Linux\r\n'
    '\r\n'
    '\x1b[1;32madonm@workstation\x1b[0m:\x1b[1;34m~\x1b[0m\$ ';

// ---------------------------------------------------------------------------
// Harness plumbing
// ---------------------------------------------------------------------------

Widget _shot(Widget child) => RepaintBoundary(
  key: _shotKey,
  child: SizedBox.expand(child: child),
);

Widget _themed(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildZukoTheme(Brightness.dark),
  home: child,
);

Future<void> _setSurface(WidgetTester tester, Size size, double ratio) async {
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = size * ratio;
  addTearDown(tester.view.reset);
}

Future<void> _pumpFrames(WidgetTester tester, int frames) async {
  // Run one fake-async frame, then let real async work (ink ripples, drawer
  // and implicit animations) settle on the real event loop. Settling first
  // prevents flterm's idle compression task from being deferred forever by
  // an in-flight animation, which would spin the scheduler's zero-delay
  // event-loop callback until the test timed out.
  for (var index = 0; index < frames; index++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // Rasterization and PNG encoding need real async in the test binding.
  final image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: tester.view.devicePixelRatio),
  ))!;
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  final directory = Directory('../docs/images');
  if (!directory.existsSync()) directory.createSync(recursive: true);
  File(
    '../docs/images/$name.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
}

Future<void> _unmountTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _unmount(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await controller.close();
}

String _flutterSdkRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  // flutter_tester lives at $FLUTTER_ROOT/bin/cache/artifacts/engine/…,
  // five directories below the SDK root.
  var directory = File(Platform.resolvedExecutable).parent;
  for (var level = 0; level < 5; level++) {
    directory = directory.parent;
  }
  return directory.path;
}

Future<void> _loadFonts() async {
  Future<void> loadAsset(String family, String asset) async {
    final data = await rootBundle.load('assets/fonts/$asset');
    final loader = FontLoader(family)..addFont(Future.value(data));
    await loader.load();
  }

  Future<void> loadFile(String family, String path) async {
    final bytes = await File(path).readAsBytes();
    final loader = FontLoader(
      family,
    )..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  await loadAsset('JetBrains Mono', 'JetBrainsMono-Regular.ttf');
  await loadAsset('JetBrains Mono', 'JetBrainsMono-Bold.ttf');
  await loadAsset(
    'JetBrainsMono Nerd Font Mono',
    'JetBrainsMonoNerdFontMono-Regular.ttf',
  );
  await loadAsset('Noto Sans Mono', 'NotoSansMono.ttf');
  await loadAsset('Noto Emoji', 'NotoEmoji-Regular.ttf');
  await loadAsset('Noto Sans Symbols 2', 'NotoSansSymbols2-Regular.ttf');
  // UI text and Material icons come from the pinned SDK's fonts so the
  // screenshots use proportional Roboto and real icon glyphs instead of the
  // test font's boxes.
  final materialFonts = Directory(
    '${_flutterSdkRoot()}/bin/cache/artifacts/material_fonts',
  );
  if (!materialFonts.existsSync()) {
    throw StateError(
      'Flutter SDK material fonts are missing at ${materialFonts.path}; '
      'run `flutter precache --universal` first.',
    );
  }
  for (final name in ['Roboto-Regular', 'Roboto-Medium', 'Roboto-Bold']) {
    await loadFile('Roboto', '${materialFonts.path}/$name.ttf');
  }
  await loadFile(
    'MaterialIcons',
    '${materialFonts.path}/MaterialIcons-Regular.otf',
  );
}

Future<AppController> _controller(
  _FakeTransport transport, {
  List<SavedHost> hosts = const [],
}) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: 'zuko-test-client',
    hosts: hosts,
  );
  final store = ClientStateStore.withStorage(_MemoryStorage());
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: transport,
  );
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _FakeTransport implements ClientTransport {
  final List<_FakeSession> sessions = [];

  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    return const ClaimResult(
      label: 'workstation',
      ticket: 'ticket',
      nodeId: 'node',
    );
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) {
    final session = _FakeSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {}
}

final class _FakeSession implements TerminalSession {
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);

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
  Future<void> close() async {}
}

final class _MemoryStorage implements SecureStateStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

/// A stand-in for a camera preview pointed at a QR code: a blurred dark
/// background with a sharp code centered where the viewfinder expects it.
class _FakeCameraPreview extends StatelessWidget {
  const _FakeCameraPreview();

  @override
  Widget build(BuildContext context) => const CustomPaint(
    painter: _FakeCameraPainter(),
    child: SizedBox.expand(),
  );
}

class _FakeCameraPainter extends CustomPainter {
  const _FakeCameraPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff3a4550), Color(0xff232c33), Color(0xff171d22)],
        ).createShader(Offset.zero & size),
    );

    // Out-of-focus background shapes.
    final random = math.Random(7);
    for (var index = 0; index < 14; index++) {
      final rect = Rect.fromCenter(
        center: Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        width: 40 + random.nextDouble() * 120,
        height: 40 + random.nextDouble() * 120,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(18)),
        Paint()..color = const Color(0xff5b6a75).withValues(alpha: 0.14),
      );
    }

    // A sharp QR-like card centered in the viewfinder.
    final card = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 216,
      height: 216,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(card, const Radius.circular(12)),
      Paint()..color = const Color(0xfff4f4ef),
    );
    const modules = 21;
    const moduleSize = 9.0;
    final origin = card.topLeft + const Offset(13.5, 13.5);
    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (!_moduleDark(random, x, y)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            origin.dx + x * moduleSize,
            origin.dy + y * moduleSize,
            moduleSize,
            moduleSize,
          ),
          Paint()..color = const Color(0xff1a1f24),
        );
      }
    }

    // Vignette so the center of the frame reads as "in focus".
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: [
            const Color(0x00000000),
            const Color(0x00000000),
            const Color(0x66000000),
          ],
          stops: const [0.5, 0.75, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  bool _moduleDark(math.Random random, int x, int y) {
    // Finder patterns in three corners.
    bool inFinder(int fx, int fy) =>
        x >= fx && x < fx + 7 && y >= fy && y < fy + 7;
    if (inFinder(0, 0) || inFinder(14, 0) || inFinder(0, 14)) {
      final localX = x % 7;
      final localY = y % 7;
      final edge = localX == 0 || localX == 6 || localY == 0 || localY == 6;
      final core = localX >= 2 && localX <= 4 && localY >= 2 && localY <= 4;
      return edge || core;
    }
    return random.nextDouble() < 0.45;
  }

  @override
  bool shouldRepaint(_FakeCameraPainter oldDelegate) => false;
}
