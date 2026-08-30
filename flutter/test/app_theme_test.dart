import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/theme.dart';

void main() {
  test('themes seed the Material palette from the zuko red', () {
    final light = buildZukoTheme(Brightness.light);
    final dark = buildZukoTheme(Brightness.dark);

    expect(
      light.colorScheme.primary,
      ColorScheme.fromSeed(seedColor: zukoRed).primary,
    );
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.visualDensity, VisualDensity.standard);
    expect(light.extension<ZukoMetrics>()!.scale, 1);
  });

  test('interface presets scale app chrome', () {
    final compact = buildZukoTheme(
      Brightness.light,
      interfaceSize: AppInterfaceSize.compact,
    );
    final standard = buildZukoTheme(Brightness.light);
    final comfortable = buildZukoTheme(
      Brightness.light,
      interfaceSize: AppInterfaceSize.comfortable,
    );

    expect(compact.visualDensity, VisualDensity.compact);
    expect(
      comfortable.visualDensity,
      const VisualDensity(horizontal: 1, vertical: 1),
    );
    expect(compact.extension<ZukoMetrics>()!.sidebarWidth, 270);
    expect(standard.extension<ZukoMetrics>()!.sidebarWidth, 300);
    expect(comfortable.extension<ZukoMetrics>()!.sidebarWidth, 345);
  });

  test('terminal palette harmonizes with the app shell', () {
    final dark = buildZukoTerminalTheme(
      brightness: Brightness.dark,
      fontSize: 16,
    );

    expect(dark.palette.ansiColors[1], zukoRed);
    expect(dark.palette.background, const Color(0xff202426));
    expect(dark.fontSize, 16);
    expect(dark.fontFamily, 'JetBrains Mono');
  });
}
