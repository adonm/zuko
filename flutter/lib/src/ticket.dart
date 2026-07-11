import 'dart:typed_data';

import 'package:iroh_flutter/iroh_flutter.dart';

final class EndpointTicket {
  const EndpointTicket._(this.address);
  final EndpointAddr address;

  static EndpointTicket parse(String value) {
    const prefix = 'endpoint';
    if (!value.startsWith(prefix)) {
      throw const FormatException('not an endpoint ticket');
    }
    final bytes = _decodeBase32(value.substring(prefix.length));
    if (bytes.length < 34 || bytes.first != 0) {
      throw const FormatException('unsupported endpoint ticket');
    }
    // iroh-tickets Variant1 is a one-byte enum tag followed by the postcard
    // EndpointAddr representation. Struct wrappers add no bytes in postcard.
    return EndpointTicket._(EndpointAddr.decode(bytes.sublist(1)));
  }
}

Uint8List _decodeBase32(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var buffer = 0;
  var bits = 0;
  final output = <int>[];
  for (final unit in input.toUpperCase().codeUnits) {
    final value = alphabet.indexOf(String.fromCharCode(unit));
    if (value < 0) {
      throw const FormatException('invalid endpoint ticket encoding');
    }
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      output.add((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0 && buffer != 0) {
    throw const FormatException('invalid endpoint ticket padding');
  }
  return Uint8List.fromList(output);
}
