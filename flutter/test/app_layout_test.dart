import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app.dart';

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

  test('wide native desktop windows use the system title bar', () {
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        usesIntegratedDesktopHeader(
          width: 1280,
          platform: platform,
          isWeb: false,
        ),
        isTrue,
      );
    }
  });

  test('web, mobile, and narrow windows keep the Flutter app bar', () {
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
    expect(
      usesIntegratedDesktopHeader(
        width: 759,
        platform: TargetPlatform.linux,
        isWeb: false,
      ),
      isFalse,
    );
  });
}
