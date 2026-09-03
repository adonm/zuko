import 'dart:convert' show base64Encode, utf8;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flterm/flterm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

/// Regression test for Kitty Unicode-placeholder (U=1) painting.
///
/// Yazi transmits images quietly (`q=2`) with `U=1` and writes `U+10EEEE`
/// placeholder cells (image id in the foreground color) instead of an
/// explicit `a=p` placement. Upstream flterm 0.0.5 skips every placement
/// that is not viewport-visible — which virtual placements never are — so
/// previews stayed visible as tofu. The forked flterm resolves placeholder
/// runs into paint snapshots (see adonm/libghostty
/// `zuko/kitty-unicode-placeholders`), and this test pins that behavior at
/// the pixel level.
///
/// Note: placeholder cells are non-BMP, so they must reach
/// `controller.write` as UTF-8 (`utf8.encode`); Dart string `.codeUnits`
/// are UTF-16 and arrive as U+FFFD, which the resolver correctly ignores.
void main() {
  testWidgets('kitty unicode placeholder paints image pixels', (tester) async {
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

    // 24x24 solid red RGBA, yazi-style quiet transmit with U=1, id 99.
    const size = 24;
    final rgba = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      rgba[i * 4] = 255;
      rgba[i * 4 + 3] = 255;
    }
    controller.write(
      Uint8List.fromList(
        '\x1b_Gq=2,a=T,C=1,U=1,f=32,s=24,v=24,i=99;${base64Encode(rgba)}'
                '\x1b\\'
            .codeUnits,
      ),
    );
    // Placeholder cells like yazi writes: fg truecolor = image id,
    // U+10EEEE + row/col diacritics.
    const placeholder = '\u{10EEEE}';
    final esc = String.fromCharCode(0x1b);
    final cells = StringBuffer()..write('$esc[38;2;0;0;99m');
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        cells.write('$placeholder\u{0305}\u{030D}');
      }
      cells.write('\r\n');
    }
    cells.write('$esc[39m');
    controller.write(utf8.encode(cells.toString()));

    // Images decode via a native callback that only fires on the real
    // event loop; painting needs a frame after decode completes.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
    }

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
  });
}
