import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show FilledButton, RepaintBoundary;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/model.dart';

import 'journey.dart';
import 'local_host_transport.dart';

/// Real-app proof of the Kitty graphics path: runs yazi in a directory
/// containing a generated test image, waits for its Kitty graphics
/// transmission, and captures the rendered preview. The kitty escape
/// sequence assertion (ESC _ G) fails the test when yazi did not pick the
/// Kitty adapter — the screenshot is the visual evidence that flterm
/// decoded and painted the image.
final _shotKey = GlobalKey();

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

Future<Directory> _directoryWithTestImage() async {
  final directory = await Directory.systemTemp.createTemp('zuko-yazi-preview');
  // Draw a distinctly colored gradient so the preview is unmistakable in
  // the screenshot.
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint()
    ..shader = ui.Gradient.linear(
      const ui.Offset(0, 0),
      const ui.Offset(120, 80),
      const [ui.Color(0xFF2E86AB), ui.Color(0xFFF18F01), ui.Color(0xFFC73E1D)],
      const [0.0, 0.5, 1.0],
    );
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 120, 80), paint);
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 80);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(
    '${directory.path}/sample.png',
  ).writeAsBytesSync(bytes!.buffer.asUint8List(), flush: true);
  return directory;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('yazi previews an image through the Kitty graphics protocol', (
    tester,
  ) async {
    final directory = await _directoryWithTestImage();
    addTearDown(() => directory.deleteSync(recursive: true));
    final transport = LocalHostTransport(
      command: [
        '/usr/bin/bash',
        '--norc',
        '-c',
        r'cd "$1" && yazi',
        'sh',
        directory.path,
      ],
    );
    final controller = await testController(
      transport,
      theme: AppThemePreference.dark,
    );
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

    // Kitty graphics transmission: ESC _ G ... ESC \. yazi emits these only
    // when it detected the Kitty adapter from the session TERM.
    var sawKittyImage = false;
    for (var attempt = 0; attempt < 80 && !sawKittyImage; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      final bytes = transport.receivedBytes;
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0x1b && bytes[i + 1] == 0x5f && bytes[i + 2] == 0x47) {
          sawKittyImage = true;
          break;
        }
      }
    }
    expect(sawKittyImage, isTrue);
    // The image decodes asynchronously and paints on a later frame; settle
    // until quiescent so the capture shows the rendered preview, not the
    // placeholder cells.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    await _capture(tester, 'yazi-preview');
  });
}
