import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/theme.dart';

void main() {
  test('light theme uses the Yaru Adwaita red variant', () {
    final theme = buildZukoTheme(Brightness.light);

    expect(theme.colorScheme.primary, YaruVariant.adwaitaRed.color);
    expect(theme.brightness, Brightness.light);
    expect(theme.visualDensity, VisualDensity.standard);
    expect(theme.extension<ZukoMetrics>()!.scale, 1);
  });

  test('dark theme uses the Yaru Adwaita red variant', () {
    final theme = buildZukoTheme(Brightness.dark);

    expect(theme.colorScheme.primary, YaruVariant.adwaitaRed.color);
    expect(theme.brightness, Brightness.dark);
  });

  test('interface presets scale Yaru typography and app chrome', () {
    final compact = buildZukoTheme(
      Brightness.light,
      interfaceSize: AppInterfaceSize.compact,
    );
    final standard = buildZukoTheme(Brightness.light);
    final comfortable = buildZukoTheme(
      Brightness.light,
      interfaceSize: AppInterfaceSize.comfortable,
    );
    final baseFontSize =
        YaruVariant.adwaitaRed.theme.textTheme.bodyMedium!.fontSize!;

    expect(
      compact.textTheme.bodyMedium!.fontSize,
      closeTo(baseFontSize * 0.95, 0.01),
    );
    expect(standard.textTheme.bodyMedium!.fontSize, baseFontSize);
    expect(
      comfortable.textTheme.bodyMedium!.fontSize,
      closeTo(baseFontSize * 1.1, 0.01),
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
    final light = buildZukoTerminalTheme(
      brightness: Brightness.light,
      fontSize: 14,
    );

    expect(dark.background, const Color(0xff202426));
    expect(dark.foreground, zukoIvory);
    expect(dark.palette.ansiColors[1], zukoRed);
    expect(dark.fontSize, 16);
    expect(
      dark.fontFamilyFallback,
      containsAll([
        'JetBrainsMono Nerd Font Mono',
        'Noto Sans JP',
        'Noto Sans KR',
      ]),
    );
    expect(light.background, const Color(0xfffcfbf2));
    expect(light.foreground, zukoCharcoal);
    expect(light.palette.ansiColors[1], zukoRed);
  });
}
