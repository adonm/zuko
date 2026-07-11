import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

Uint8List deriveHandoffKey(String code) {
  final normalized = code.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        Uint8List.fromList(utf8.encode('zuko-share-handoff-v1')),
        desiredKeyLength: 32,
        version: Argon2Parameters.ARGON2_VERSION_13,
        iterations: 2,
        memory: 19456,
        lanes: 1,
      ),
    );
  return generator.process(Uint8List.fromList(utf8.encode(normalized)));
}

Uint8List deriveSessionToken(List<int> clientKey, List<int> hostId) =>
    Uint8List.fromList(
      sha256
          .convert([
            ...utf8.encode('zuko-session-token-v1'),
            ...clientKey,
            ...hostId,
          ])
          .bytes
          .take(16)
          .toList(),
    );
