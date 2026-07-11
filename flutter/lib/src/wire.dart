import 'dart:convert';
import 'dart:typed_data';

const sessionAlpn = <int>[0x7a, 0x75, 0x6b, 0x6f, 0x2f, 0x32];
const tunnelAlpn = <int>[
  0x7a,
  0x75,
  0x6b,
  0x6f,
  0x2f,
  0x74,
  0x75,
  0x6e,
  0x6e,
  0x65,
  0x6c,
  0x2f,
  0x31,
];
const handoffAlpn = <int>[
  0x7a,
  0x75,
  0x6b,
  0x6f,
  0x2f,
  0x68,
  0x61,
  0x6e,
  0x64,
  0x6f,
  0x66,
  0x66,
  0x2f,
  0x31,
];

abstract final class WireType {
  static const data = 0x00;
  static const resize = 0x01;
  static const ping = 0x04;
  static const pong = 0x05;
  static const attach = 0x06;
  static const attached = 0x07;
  static const authorize = 0x08;
  static const error = 0x09;
  static const tunnelOffer = 0x0a;
  static const tunnelClose = 0x0b;
  static const tunnelAttach = 0x0c;
  static const tunnelAttached = 0x0d;
}

final class WireFrame {
  const WireFrame(this.type, this.payload);
  final int type;
  final Uint8List payload;
}

Uint8List encodeFrame(int type, List<int> payload) {
  if (payload.length > 0xffff) {
    throw ArgumentError('frame payload exceeds 65535 bytes');
  }
  return Uint8List.fromList([
    type,
    payload.length >> 8,
    payload.length,
    ...payload,
  ]);
}

Iterable<Uint8List> encodeData(List<int> bytes) sync* {
  for (var offset = 0; offset < bytes.length; offset += 0xffff) {
    final end = (offset + 0xffff).clamp(0, bytes.length);
    yield encodeFrame(WireType.data, bytes.sublist(offset, end));
  }
}

Uint8List encodeAttach(List<int> token, TerminalGeometry size) {
  if (token.length != 16) throw ArgumentError('session token must be 16 bytes');
  return encodeFrame(WireType.attach, [...token, ..._geometry(size)]);
}

Uint8List encodeAuthorize(List<int> token, String label) {
  if (token.length != 16) throw ArgumentError('session token must be 16 bytes');
  final bytes = Uint8List.fromList(utf8.encode(label));
  return encodeFrame(WireType.authorize, [
    ...token,
    ...bytes.take(0xffff - 16),
  ]);
}

Uint8List encodeTunnelAttach(List<int> token, List<int> id) {
  if (token.length != 16) throw ArgumentError('session token must be 16 bytes');
  if (id.length != 16) throw ArgumentError('tunnel id must be 16 bytes');
  return encodeFrame(WireType.tunnelAttach, [...token, ...id]);
}

({Uint8List id, int port})? decodeTunnelOffer(List<int> payload) {
  if (payload.length != 18) return null;
  final port = (payload[16] << 8) | payload[17];
  if (port == 0) return null;
  return (id: Uint8List.fromList(payload.take(16).toList()), port: port);
}

Uint8List encodeResize(TerminalGeometry size) =>
    encodeFrame(WireType.resize, _geometry(size));

Uint8List encodePong(List<int> nonce) => encodeFrame(
  WireType.pong,
  nonce.length >= 8 ? nonce.take(8).toList() : List.filled(8, 0),
);

List<int> _geometry(TerminalGeometry size) => [
  ..._u16(size.cols),
  ..._u16(size.rows),
  ..._u16(size.pixelWidth),
  ..._u16(size.pixelHeight),
];

List<int> _u16(int value) {
  final safe = value.clamp(0, 0xffff);
  return [safe >> 8, safe];
}

final class TerminalGeometry {
  const TerminalGeometry(
    this.cols,
    this.rows,
    this.pixelWidth,
    this.pixelHeight,
  );
  final int cols;
  final int rows;
  final int pixelWidth;
  final int pixelHeight;
}

final class WireDecoder {
  final List<int> _pending = [];

  List<WireFrame> add(List<int> bytes) {
    _pending.addAll(bytes);
    final frames = <WireFrame>[];
    while (_pending.length >= 3) {
      final length = (_pending[1] << 8) | _pending[2];
      if (_pending.length < length + 3) break;
      frames.add(
        WireFrame(
          _pending[0],
          Uint8List.fromList(_pending.sublist(3, length + 3)),
        ),
      );
      _pending.removeRange(0, length + 3);
    }
    return frames;
  }
}
