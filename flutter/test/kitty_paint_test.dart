import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

/// Regression test for Kitty image painting.
///
/// Proven so far: transmissions store correctly (a `Gi=<id>;OK` query
/// response), for raw RGBA and PNG payloads, across `a=T`, `a=t` + `a=p`,
/// and yazi-style (`C`/`R`/`U`) parameter variants — yet zero image pixels
/// paint, and Unicode-placeholder cells stay visible as tofu. The break is
/// therefore between Kitty storage and the flterm paint path (placement
/// sync, async decode completion, or the painter), inside flterm/libghostty
/// rather than zuko code.
///
/// Skipped until the upstream paint path is fixed; remove the skip to
/// re-prove. See the yazi preview capture
/// (`flutter/integration/integration_test/yazi_image_preview_screenshot_test.dart`),
/// which shows the same symptom against a real TUI.
void main() {
  testWidgets(
    'kitty rgba transmission paints image pixels',
    (tester) async {
      final controller = TerminalController();
      addTearDown(controller.dispose);
      final shotKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox.expand(
            child: RepaintBoundary(
              key: shotKey,
              child: TerminalView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      // 4x4 solid red RGBA, transmitted and displayed at the cursor.
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        rgba[i * 4] = 255;
        rgba[i * 4 + 3] = 255;
      }
      controller.write(
        Uint8List.fromList(
          '\x1b_Ga=T,f=32,s=4,v=4,i=7;${base64Encode(rgba)}\x1b\\'.codeUnits,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final renderObject =
          shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync<ui.Image?>(
        () => renderObject.toImage(pixelRatio: 1),
      );
      final bytes = await tester.runAsync<ByteData?>(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final pixels = bytes!.buffer.asUint8List();
      var red = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] > 200 && pixels[i + 1] < 80 && pixels[i + 2] < 80) {
          red++;
        }
      }
      expect(red, greaterThan(0));
    },
    // Skipped until the upstream paint path is fixed (see above); flip back
    // to `skip: false` to re-prove.
    skip: true,
  );
}
