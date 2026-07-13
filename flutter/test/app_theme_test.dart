import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaru/yaru.dart';
import 'package:zuko/src/theme.dart';

void main() {
  test('light theme uses the Yaru Adwaita red variant', () {
    final theme = buildZukoTheme(Brightness.light);

    expect(theme, same(YaruVariant.adwaitaRed.theme));
    expect(theme.colorScheme.primary, YaruVariant.adwaitaRed.color);
    expect(theme.brightness, Brightness.light);
  });

  test('dark theme uses the Yaru Adwaita red variant', () {
    final theme = buildZukoTheme(Brightness.dark);

    expect(theme, same(YaruVariant.adwaitaRed.darkTheme));
    expect(theme.colorScheme.primary, YaruVariant.adwaitaRed.color);
    expect(theme.brightness, Brightness.dark);
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
