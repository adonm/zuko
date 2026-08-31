import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show FilledButton, RepaintBoundary;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/storage.dart';

import 'local_host_transport.dart';

/// Real-app screenshots of the touch shell with live TUI content: runs with
/// ZUKO_FORCE_TOUCH_PAD and a btop PTY so the pad floats over a real
/// mouse-capable terminal program. ZUKO_SHOT_NAME renames the capture so
/// the same test can record several window sizes (see the screenshots
/// recipe).
final _shotKey = GlobalKey();

const _shotName = String.fromEnvironment(
  'ZUKO_SHOT_NAME',
  defaultValue: 'touch-btop',
);

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync<ui.Image?>(
    () => boundary.toImage(pixelRatio: 2),
  ))!;
  final bytes = (await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  ))!;
  final directory = Directory('../../docs/images');
  directory.createSync(recursive: true);
  File(
    '${directory.path}/$name.png',
  ).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture the btop terminal with the floating pad', (
    tester,
  ) async {
    final transport = LocalHostTransport(
      command: const ['/usr/bin/bash', '--norc', '-c', 'btop'],
    );
    final controller = await _controller(transport);
    addTearDown(controller.close);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: ZukoApp(controller: controller),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.bySemanticsLabel(RegExp('Share code')),
      'alpha-bravo',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();

    // Wait for btop's first frames.
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (transport.receivedBytes.contains(0x1b)) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
    await _capture(tester, _shotName);
  });
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

Future<AppController> _controller(LocalHostTransport transport) async {
  final state = ClientState(
    clientKey: Uint8List.fromList(List<int>.generate(32, (index) => index)),
    clientName: 'zuko-test-client',
    hosts: const [],
  );
  final store = ClientStateStore.withStorage(_MemoryStorage());
  await store.save(state);
  return AppController.forTesting(
    store: store,
    state: state,
    transport: transport,
  );
}
