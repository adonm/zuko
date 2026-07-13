import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';
import 'package:zuko/src/window_frame.dart';

void main() {
  test('terminal accessory row is half the previous height', () {
    expect(terminalAccessoryHeight, 24);
  });

  test('screens use responsive defaults until the user chooses a size', () {
    expect(
      effectiveTerminalFontSize(
        width: 390,
        configuredSize: 14,
        customized: false,
      ),
      7,
    );
    expect(
      effectiveTerminalFontSize(
        width: 1280,
        configuredSize: 14,
        customized: false,
      ),
      10,
    );
    expect(
      effectiveTerminalFontSize(
        width: 390,
        configuredSize: 9,
        customized: true,
      ),
      9,
    );
  });

  test('Linux always uses the integrated Yaru window title bar', () {
    expect(
      usesYaruWindowTitleBar(platform: TargetPlatform.linux, isWeb: false),
      isTrue,
    );
    for (final width in [390.0, 1280.0]) {
      expect(
        usesIntegratedDesktopHeader(
          width: width,
          platform: TargetPlatform.linux,
          isWeb: false,
        ),
        isTrue,
      );
    }
  });

  test('wide macOS and Windows layouts keep their native title bars', () {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      expect(
        usesIntegratedDesktopHeader(
          width: 1280,
          platform: platform,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        usesIntegratedDesktopHeader(
          width: 759,
          platform: platform,
          isWeb: false,
        ),
        isFalse,
      );
    }
  });

  test('web and mobile layouts keep the Flutter app bar', () {
    expect(
      usesYaruWindowTitleBar(platform: TargetPlatform.linux, isWeb: true),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        width: 1280,
        platform: TargetPlatform.linux,
        isWeb: true,
      ),
      isFalse,
    );
    expect(
      usesIntegratedDesktopHeader(
        width: 1280,
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isFalse,
    );
  });
}
