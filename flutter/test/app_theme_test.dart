import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/theme.dart';

void main() {
  test('light theme uses the icon palette and Adwaita-like surfaces', () {
    final theme = buildZukoTheme(Brightness.light);

    expect(theme.colorScheme.primary, zukoRed);
    expect(theme.colorScheme.onSurface, zukoCharcoal);
    expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
    expect(theme.appBarTheme.toolbarHeight, 52);
    expect(theme.appBarTheme.centerTitle, isTrue);
    expect(theme.cardTheme.elevation, 0);

    final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius.resolve(TextDirection.ltr).topLeft.x, 12);
    expect(shape.side.color, theme.colorScheme.outlineVariant);
  });

  test('dark theme keeps the charcoal and ivory icon colors', () {
    final theme = buildZukoTheme(Brightness.dark);

    expect(theme.colorScheme.surfaceContainer, zukoCharcoal);
    expect(theme.colorScheme.onSurface, zukoIvory);
    expect(theme.colorScheme.primary, const Color(0xffe06b73));
    expect(
      theme.drawerTheme.backgroundColor,
      theme.colorScheme.surfaceContainerLow,
    );
    expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
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
    expect(light.background, const Color(0xfffcfbf2));
    expect(light.foreground, zukoCharcoal);
    expect(light.palette.ansiColors[1], zukoRed);
  });
}
