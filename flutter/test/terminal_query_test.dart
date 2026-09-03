import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the terminal query/response path that mouse-capable TUIs depend
/// on: yazi probes the terminal before picking its image adapter and sizing
/// previews, so a dependency upgrade that silences these responses would
/// break image previews and layout without any test failing otherwise.
///
/// These run against a bare controller (no laid-out view), so pixel-size
/// queries answer zeros — the regression value is that they are answered
/// at all, in the right format.
void main() {
  late TerminalController controller;
  late List<int> out;

  setUp(() {
    controller = TerminalController();
    out = <int>[];
    controller.onOutput = (bytes) => out.addAll(bytes);
  });

  tearDown(() => controller.dispose());

  Future<String> query(String sequence) async {
    out.clear();
    controller.write(Uint8List.fromList(sequence.codeUnits));
    // Responses are emitted synchronously during write; yield once so any
    // async follow-ups settle.
    await Future<void>.delayed(Duration.zero);
    return String.fromCharCodes(out);
  }

  test('answers primary device attributes (DA1)', () async {
    expect(await query('\x1b[c'), '\x1b[?62c');
  });

  test('answers secondary device attributes', () async {
    expect(await query('\x1b[>c'), '\x1b[>1;0;0c');
  });

  test('answers cursor position report at home', () async {
    expect(await query('\x1b[6n'), '\x1b[1;1R');
  });

  test('answers kitty keyboard enhancement flags', () async {
    expect(await query('\x1b[?u'), '\x1b[?0u');
  });

  test('answers pixel-size queries in CSI t format', () async {
    // No laid-out view here, so dimensions are zero — what matters is the
    // well-formed response (CSI 6 for cell, CSI 4 for text area).
    expect(await query('\x1b[16t'), startsWith('\x1b[6;'));
    expect(await query('\x1b[14t'), startsWith('\x1b[4;'));
  });
}
