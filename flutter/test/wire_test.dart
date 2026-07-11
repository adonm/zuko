import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/wire.dart';

void main() {
  test('encodes data and resize frames', () {
    expect(encodeData('hello'.codeUnits).single, [
      0,
      0,
      5,
      104,
      101,
      108,
      108,
      111,
    ]);
    expect(encodeResize(const TerminalGeometry(80, 24, 800, 600)), [
      1,
      0,
      8,
      0,
      80,
      0,
      24,
      3,
      32,
      2,
      88,
    ]);
  });

  test('decoder handles partial and adjacent frames', () {
    final decoder = WireDecoder();
    final bytes = Uint8List.fromList([
      ...encodeFrame(WireType.data, [1, 2]),
      ...encodeFrame(WireType.ping, List.filled(8, 3)),
    ]);
    expect(decoder.add(bytes.sublist(0, 2)), isEmpty);
    final frames = decoder.add(bytes.sublist(2));
    expect(frames.map((frame) => frame.type), [WireType.data, WireType.ping]);
    expect(frames.first.payload, [1, 2]);
  });

  test('chunks terminal input at the wire maximum', () {
    final frames = encodeData(List.filled(70000, 1)).toList();
    expect(frames, hasLength(2));
    expect(frames.first.length, 65538);
  });

  test('allows unknown pixel geometry to be sent as zero', () {
    expect(encodeResize(const TerminalGeometry(80, 24, 0, 0)), [
      1,
      0,
      8,
      0,
      80,
      0,
      24,
      0,
      0,
      0,
      0,
    ]);
  });
}
