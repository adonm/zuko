import 'package:flutter/foundation.dart';

import 'device_hostname.dart';

const maxClientNameLength = 40;

String normalizeClientName(String value) {
  var normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '-',
  );
  normalized = normalized.replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.runes.length > maxClientNameLength) {
    normalized = String.fromCharCodes(
      normalized.runes.take(maxClientNameLength),
    ).replaceAll(RegExp(r'-+$'), '');
  }
  return normalized;
}

String clientAuthorizationLabel(String clientName, Uint8List clientKey) {
  final name = normalizeClientName(clientName);
  final fingerprint = clientKey
      .take(3)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'zuko-${name.isEmpty ? 'device' : name}-$fingerprint';
}

Future<String> suggestClientName() async {
  final fallback = _platformFallback();
  try {
    return firstUsableClientName([readDeviceHostname()], fallback: fallback);
  } on Object {
    return fallback;
  }
}

@visibleForTesting
String firstUsableClientName(
  Iterable<String?> candidates, {
  required String fallback,
}) {
  const genericNames = {
    'unknown',
    'localhost',
    'android',
    'iphone',
    'ipad',
    'macos',
    'windows',
    'linux',
  };
  for (final candidate in candidates) {
    final normalized = normalizeClientName(candidate ?? '');
    if (normalized.isNotEmpty && !genericNames.contains(normalized)) {
      return normalized;
    }
  }
  final normalizedFallback = normalizeClientName(fallback);
  return normalizedFallback.isEmpty ? 'device' : normalizedFallback;
}

String _platformFallback() {
  if (kIsWeb) return 'web-client';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android-device',
    TargetPlatform.iOS => 'ios-device',
    TargetPlatform.macOS => 'mac',
    TargetPlatform.windows => 'windows-pc',
    TargetPlatform.linux => 'linux-pc',
    TargetPlatform.fuchsia => 'device',
  };
}
