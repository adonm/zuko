import 'package:device_info_plus/device_info_plus.dart';
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

Future<String> suggestClientName({DeviceInfoPlugin? deviceInfo}) async {
  final fallback = _platformFallback();
  try {
    final plugin = deviceInfo ?? DeviceInfoPlugin();
    if (kIsWeb) {
      final info = await plugin.webBrowserInfo;
      return firstUsableClientName([
        '${_browserName(info.browserName)}-web',
      ], fallback: fallback);
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final info = await plugin.androidInfo;
        return firstUsableClientName([
          info.name,
          '${info.manufacturer} ${info.model}',
          info.model,
        ], fallback: fallback);
      case TargetPlatform.iOS:
        final info = await plugin.iosInfo;
        return firstUsableClientName([
          info.modelName,
          info.localizedModel,
          info.model,
        ], fallback: fallback);
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return firstUsableClientName([
          readDeviceHostname(),
        ], fallback: fallback);
      case TargetPlatform.fuchsia:
        return fallback;
    }
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

String _browserName(BrowserName name) => switch (name) {
  BrowserName.samsungInternet => 'samsung-internet',
  BrowserName.msie => 'internet-explorer',
  BrowserName.unknown => 'browser',
  _ => name.name,
};
